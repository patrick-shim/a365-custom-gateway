import { z } from "zod";

const blockedSchema = z.object({evaluationId:z.string().uuid(),errorCode:z.enum([
  "PROMPT_BLOCKED_BY_PROMPT_SHIELD","PROMPT_BLOCKED_BY_DLP","PROMPT_BLOCKED_BY_MULTIPLE_CONTROLS"]),
  promptShieldProcessing:z.string(),purviewProcessing:z.string(),correlationId:z.string()});

const evaluationSchema = z.object({
  evaluationId: z.string().uuid(), evaluationReceiptId: z.string().uuid().nullable(), interactionId: z.string(),
  allowed: z.boolean(), decision: z.string(), promptShieldProcessing: z.string(), purviewProcessing: z.string(),
  userMessage: z.string(), correlationId: z.string(),
});
const activitySchema = z.object({receiptId:z.string().uuid(), activityId:z.string(), status:z.string(), correlationId:z.string().nullable()});
const interactionSchema = z.object({receiptId:z.string().uuid(), interactionId:z.string(), status:z.string(),
  purviewProcessing:z.string().nullable(), observabilityProcessing:z.string().nullable(), correlationId:z.string().nullable()});
export type TestStep = { name: string; status: "Running" | "Succeeded" | "Accepted" | "Blocked" | "Failed" | "Unconfirmed" | "Skipped"; detail: string; reference?: string };
export type AgentTestResult = { runId:string; outcome:"Succeeded"|"Blocked"|"Failed"|"Partial"; steps:TestStep[] };
export const simulatedResponse = "Gateway Console simulation completed. This is a test response; no language model was called.";

class TestRequestError extends Error { constructor(message:string, readonly uncertain=false) { super(message); } }
async function post(path:string, key:string, body:unknown, signal:AbortSignal) {
  let response:Response;
  const controller=new AbortController();
  const abort=()=>controller.abort();
  if(signal.aborted)controller.abort();
  signal.addEventListener("abort",abort,{once:true});
  const timer=setTimeout(abort,90_000);
  try {
    response=await fetch(path,{method:"POST",credentials:"omit",cache:"no-store",redirect:"error",
      headers:{Authorization:`Bearer ${key}`,"Content-Type":"application/json","Idempotency-Key":crypto.randomUUID()},
      body:JSON.stringify(body),signal:controller.signal});
  } catch {
    clearTimeout(timer);signal.removeEventListener("abort",abort);
    throw new TestRequestError("No response was received. The request may have been processed; this test will not automatically resend it.",true);
  }
  let value:unknown;
  try { value=await response.json(); } catch { throw new TestRequestError("The gateway returned an unreadable response. Delivery is unconfirmed.",true); }
  finally {clearTimeout(timer);signal.removeEventListener("abort",abort);}
  return { response,value };
}
function failure(status:number):never {
  // Never echo an arbitrary dependency body: it could contain a key or prompt.
  const message=status===401 ? "API key rejected. Check that it is current and belongs to this agent."
    :status===403 ? "Access denied. Check the agent, API key and user context."
    :status===409 ? "The agent or protection settings changed. Review its current state before starting a new test."
    :status===400 ? "The gateway rejected the test fields. Check the user object ID and prompt."
    :`Gateway request failed (HTTP ${status}). Check service health and the agent's settings.`;
  throw new TestRequestError(message,status>=500);
}
export async function simulateAgent(input:{externalAgentId:string;apiKey:string;prompt:string;userObjectId:string},
  signal:AbortSignal, onSteps:(steps:TestStep[])=>void):Promise<AgentTestResult> {
  const runId=`console-test-${crypto.randomUUID()}`;
  const steps:TestStep[]=[];
  const publish=(step:TestStep)=>{const index=steps.findIndex(s=>s.name===step.name);if(index<0)steps.push(step);else steps[index]=step;onSteps([...steps]);};
  const failed=(name:string,e:unknown)=>publish({name,status:e instanceof TestRequestError&&e.uncertain?"Unconfirmed":"Failed",
    detail:e instanceof TestRequestError?e.message:"Unexpected test response. Check the gateway before starting another test."});
  const common={externalAgentId:input.externalAgentId,interactionId:runId,occurredAtUtc:new Date().toISOString(),
    userContext:{tenantUserObjectId:input.userObjectId},prompt:{contentType:"text/plain",content:input.prompt}};
  let evaluation:z.infer<typeof evaluationSchema>;
  publish({name:"Prompt evaluation",status:"Running",detail:"Checking the agent's current Prompt Shields and Purview settings…"});
  try {
    const {response,value}=await post("/api/v1/prompts:evaluate",input.apiKey,common,signal);
    const blocked = response.status===403 ? blockedSchema.safeParse(value) : null;
    const parsed=evaluationSchema.safeParse(blocked?.success ? {
      ...blocked.data, allowed:false, evaluationReceiptId:null,interactionId:runId,decision:blocked.data.errorCode,userMessage:"Prompt blocked"
    } : value);
    if(!parsed.success){if(!response.ok)failure(response.status);throw new TestRequestError("Prompt evaluation response is invalid. No simulated interaction was sent.",true);}
    evaluation=parsed.data;
    if(evaluation.interactionId!==runId || (evaluation.allowed ? response.status!==200||!evaluation.evaluationReceiptId : response.status!==403))
      throw new TestRequestError("Prompt evaluation did not match this test. No simulated interaction was sent.",true);
    publish({name:"Prompt evaluation",status:evaluation.allowed?"Succeeded":"Blocked",
      detail:`${evaluation.allowed?"Allowed":"Blocked"}. Prompt Shields: ${evaluation.promptShieldProcessing}. Purview: ${evaluation.purviewProcessing}.`,reference:evaluation.correlationId});
  } catch(e) { failed("Prompt evaluation",e);return {runId,outcome:"Failed",steps}; }
  publish({name:"Activity telemetry",status:"Running",detail:"Submitting agent activity…"});
  try {
    const {response,value}=await post("/api/v1/agent-activities",input.apiKey,{
      externalAgentId:input.externalAgentId,activityId:runId,sessionId:runId,activityType:"Chat",occurredAtUtc:new Date().toISOString(),
      actor:{type:"User",tenantUserObjectId:input.userObjectId},attributes:{source:"GatewayConsoleSimulator",promptDecision:evaluation.decision}},signal);
    if(!response.ok)failure(response.status);
    const receipt=activitySchema.parse(value);
    if(response.status!==202||receipt.activityId!==runId)throw new TestRequestError("Activity receipt did not match this test.",true);
    publish({name:"Activity telemetry",status:"Accepted",detail:`Accepted by gateway (${receipt.status}). Downstream delivery is not yet confirmed.`,reference:receipt.receiptId});
  } catch(e) { failed("Activity telemetry",e); }
  if(!evaluation.allowed) {
    publish({name:"AI interaction",status:"Skipped",detail:"Prompt blocked. No simulated model response or interaction was submitted."});
    return {runId,outcome:"Blocked",steps};
  }
  publish({name:"AI interaction",status:"Running",detail:"Submitting the prompt and labeled simulated response…"});
  try {
    const {response,value}=await post("/api/v1/ai-interactions",input.apiKey,{...common,sessionId:runId,
      response:{contentType:"text/plain",content:simulatedResponse},metadata:{source:"GatewayConsoleSimulator",simulated:"true"},
      promptEvaluationReceiptId:evaluation.evaluationReceiptId},signal);
    if(!response.ok)failure(response.status);
    const receipt=interactionSchema.parse(value);
    if(response.status!==202||receipt.interactionId!==runId)throw new TestRequestError("Interaction receipt did not match this test.",true);
    if(receipt.status==="Failed")throw new TestRequestError("The gateway accepted the record but reported failed interaction processing. Check the agent's Purview configuration.");
    publish({name:"AI interaction",status:"Accepted",detail:`Accepted. Purview: ${receipt.purviewProcessing??"Not reported"}; observability: ${receipt.observabilityProcessing??"Not reported"}.`,reference:receipt.receiptId});
  } catch(e) { failed("AI interaction",e); }
  return {runId,outcome:steps.some(s=>s.status==="Failed"||s.status==="Unconfirmed")?"Partial":"Succeeded",steps};
}
