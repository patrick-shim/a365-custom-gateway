import { beforeEach, expect, it, vi } from "vitest";
import { simulateAgent } from "./simulator";
const receipt="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const input={externalAgentId:"selected-agent",apiKey:"test-secret",prompt:"test prompt",userObjectId:"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"};
beforeEach(()=>vi.restoreAllMocks());
function mock(mode="allowed") {
  return vi.spyOn(globalThis,"fetch").mockImplementation(async (url, init)=>{
    const body=JSON.parse(String(init?.body));
    if(String(url).endsWith("prompts:evaluate")) {
      if(mode==="unauthorized")return new Response(JSON.stringify({detail:input.apiKey}),{status:401});
      if(mode==="blocked")return new Response(JSON.stringify({evaluationId:receipt,errorCode:"PROMPT_BLOCKED_BY_PROMPT_SHIELD",promptShieldProcessing:"Blocked",purviewProcessing:"Disabled",correlationId:receipt}),{status:403});
      return new Response(JSON.stringify({evaluationId:receipt,evaluationReceiptId:receipt,interactionId:body.interactionId,allowed:true,decision:"Allow",promptShieldProcessing:"Disabled",purviewProcessing:"Disabled",userMessage:"Allowed",correlationId:receipt}),{status:200});
    }
    if(String(url).endsWith("agent-activities"))return new Response(JSON.stringify({receiptId:receipt,activityId:body.activityId,status:"Accepted",correlationId:receipt}),{status:202});
    if(mode==="partial")throw new Error("network lost");
    return new Response(JSON.stringify({receiptId:receipt,interactionId:body.interactionId,status:"Accepted",purviewProcessing:"PurviewDisabled",observabilityProcessing:"Pending",correlationId:receipt}),{status:202});
  });
}
it("uses the selected agent key on real routes and binds the evaluated prompt to the interaction",async()=>{
  const fetch=mock();const result=await simulateAgent(input,new AbortController().signal,()=>{});
  expect(result.outcome).toBe("Succeeded");expect(fetch).toHaveBeenCalledTimes(3);
  const bodies=fetch.mock.calls.map(([,i])=>JSON.parse(String(i?.body)));
  for(const [,i] of fetch.mock.calls)expect(new Headers(i?.headers).get("Authorization")).toBe("Bearer test-secret");
  expect(bodies[2].promptEvaluationReceiptId).toBe(receipt);
  expect(bodies[2].prompt).toEqual(bodies[0].prompt);expect(bodies[2].interactionId).toBe(bodies[0].interactionId);
  expect(bodies[2].metadata.simulated).toBe("true");
  expect(JSON.stringify(result)).not.toContain(input.apiKey);
});
it("recognizes actual blocked ProblemDetails and never submits an AI interaction",async()=>{
  const fetch=mock("blocked");const result=await simulateAgent(input,new AbortController().signal,()=>{});
  expect(result.outcome).toBe("Blocked");expect(fetch).toHaveBeenCalledTimes(2);
  expect(result.steps.at(-1)?.status).toBe("Skipped");
});
it("distinguishes invalid keys from protection blocks without displaying provider bodies",async()=>{
  const fetch=mock("unauthorized");const result=await simulateAgent(input,new AbortController().signal,()=>{});
  expect(result.outcome).toBe("Failed");expect(fetch).toHaveBeenCalledTimes(1);
  expect(JSON.stringify(result)).not.toContain(input.apiKey);
});
it("reports lost interaction responses as unconfirmed and never replays them",async()=>{
  const fetch=mock("partial");const result=await simulateAgent(input,new AbortController().signal,()=>{});
  expect(result.outcome).toBe("Partial");expect(result.steps.at(-1)?.status).toBe("Unconfirmed");expect(fetch).toHaveBeenCalledTimes(3);
});
it.each([
  [409,"PURVIEW_ASSIGNMENT_NOT_READY","Purview protection is not ready"],
  [409,"PURVIEW_INVENTORY_STALE","policy catalog is stale"],
  [403,"PROMPT_EVALUATION_INVALID","current policy scope could not be verified"],
  [403,"AGENT_IDENTITY_MISMATCH","different agent"],
  [403,"AGENT_DISABLED","disabled in the gateway"],
])("explains HTTP %s %s without sending downstream telemetry",async(status,errorCode,message)=>{
  const fetch=vi.spyOn(globalThis,"fetch").mockResolvedValue(new Response(JSON.stringify({errorCode,detail:input.apiKey,correlationId:receipt}),{status:Number(status)}));
  const result=await simulateAgent(input,new AbortController().signal,()=>{});
  expect(result.outcome).toBe("Failed");expect(fetch).toHaveBeenCalledTimes(1);
  expect(result.steps[0].detail).toContain(message);
  expect(result.steps[0].reference).toBe(receipt);
  expect(JSON.stringify(result)).not.toContain(input.apiKey);
});
it("does not echo unknown error codes or unsafe references",async()=>{
  vi.spyOn(globalThis,"fetch").mockResolvedValue(new Response(JSON.stringify({errorCode:input.apiKey,correlationId:input.apiKey,detail:input.apiKey}),{status:403}));
  const result=await simulateAgent(input,new AbortController().signal,()=>{});
  expect(result.steps[0].detail).toContain("Access denied");
  expect(JSON.stringify(result)).not.toContain(input.apiKey);
});
