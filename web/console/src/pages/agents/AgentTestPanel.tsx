import { useEffect, useRef, useState } from "react";
import { OverlayDrawer, DrawerHeader, DrawerHeaderTitle, DrawerBody, Button, Field, Input, Textarea, Text, Spinner, Card } from "@fluentui/react-components";
import { Dismiss24Regular, Play24Regular } from "@fluentui/react-icons";
import { getAccount } from "../../auth/msal";
import { simulateAgent, type TestStep, type AgentTestResult } from "../../api/simulator";
import { StatusPill } from "../../components/StatusPill";

type TestAgent = {agentId:string;name:string;externalAgentId:string;status:string};
export function AgentTestPanel({agent,onClose}:{agent:TestAgent;onClose:()=>void}) {
  const [key,setKey]=useState(""); const [prompt,setPrompt]=useState("");
  const [user,setUser]=useState(String(getAccount()?.idTokenClaims?.oid??""));
  const [steps,setSteps]=useState<TestStep[]>([]); const [result,setResult]=useState<AgentTestResult>();
  const [busy,setBusy]=useState(false); const [error,setError]=useState("");
  const controller=useRef<AbortController>();
  useEffect(()=>()=>controller.current?.abort(),[]);
  async function run() {
    setBusy(true);setResult(undefined);setError("");setSteps([]);
    controller.current=new AbortController();
    const apiKey=key.trim();setKey("");
    try {setResult(await simulateAgent({externalAgentId:agent.externalAgentId,apiKey,prompt,userObjectId:user.trim()},controller.current.signal,setSteps));}
    catch {setError("The test stopped unexpectedly. Its outcome is unconfirmed; check the gateway before running again.");}
    finally {setBusy(false);}
  }
  const validUser=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(user.trim())&&!/^0{8}-0{4}-0{4}-0{4}-0{12}$/.test(user.trim());
  return <OverlayDrawer open position="end" size="medium" onOpenChange={(_,d)=>{if(!d.open&&!busy)onClose();}}>
    <DrawerHeader><DrawerHeaderTitle action={<Button appearance="subtle" aria-label="Close agent test" icon={<Dismiss24Regular/>} disabled={busy} onClick={onClose}/>}>Test Agent</DrawerHeaderTitle></DrawerHeader>
    <DrawerBody style={{display:"flex",flexDirection:"column",gap:18,paddingBottom:24}}>
      <Text size={500} weight="semibold">{agent.name}</Text>
      <Field label="External agent ID"><Input value={agent.externalAgentId} readOnly/></Field>
      <Text>This sends real requests using this agent's current gateway settings. Allowed prompts use a labeled simulated response; no language model is called.</Text>
      <Field label="Registered API key" hint="Used only for this run. Never saved; cleared when sent or closed."><Input type="password" autoComplete="off" value={key} disabled={busy} onChange={(_,d)=>setKey(d.value)}/></Field>
      <Field label="Test prompt" hint="The prompt may be recorded by the configured Microsoft services."><Textarea value={prompt} rows={5} maxLength={8000} disabled={busy} onChange={(_,d)=>setPrompt(d.value)}/></Field>
      <Field label="User object ID" hint="Prefilled with your signed-in Entra user. Used for Agent 365 and Purview user context."><Input value={user} disabled={busy} onChange={(_,d)=>setUser(d.value)}/></Field>
      <Button appearance="primary" icon={<Play24Regular/>} disabled={busy||agent.status!=="Active"||!key.trim()||!prompt.trim()||!validUser} onClick={()=>void run()}>Send test prompt</Button>
      {agent.status!=="Active"&&<Text>This agent must be Active before testing.</Text>}
      <div aria-live="polite" aria-busy={busy} style={{display:"grid",gap:12}}>
        {busy&&<Spinner size="small" label="Running agent test…"/>}
        {result&&<Text size={500} weight="semibold">{result.outcome==="Succeeded"?"Succeeded — gateway accepted the test":result.outcome==="Partial"?"Partially succeeded — check each step":result.outcome==="Blocked"?"Blocked by protection":"Test failed"}</Text>}
        {error&&<Text role="alert">{error}</Text>}
        {steps.map(step=><Card key={step.name}><Text weight="semibold">{step.name}</Text><StatusPill value={step.status}/><Text>{step.detail}</Text>{step.reference&&<Text size={200} style={{overflowWrap:"anywhere"}}>Reference: {step.reference}</Text>}</Card>)}
      </div>
      {result&&<Text size={200} style={{overflowWrap:"anywhere"}}>Test ID: {result.runId}</Text>}
      <Text size={200}>Accepted or queued is not proof of visibility in Agent 365, Purview AI Explorer, or Defender. Prompt Shields events follow the deployment's security telemetry configuration; this panel does not confirm Defender ingestion. A blocked prompt does not generate a simulated AI response.</Text>
    </DrawerBody>
  </OverlayDrawer>;
}
