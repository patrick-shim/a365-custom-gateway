import { useEffect, useRef, useState, type ReactNode } from 'react';
import { createRoot } from 'react-dom/client';
import { Button, Checkbox, FluentProvider, Input, Select, Spinner, webLightTheme } from '@fluentui/react-components';
import { defaults, submission, type Configuration } from './configuration';
import './style.css';

type Event={type:string;message?:string;data?:any};
type Progress={running:boolean;exitCode:number|null;action:string;events:Event[];reviewedPlan?:string};
function Field({label,hint,children}:{label:string;hint?:string;children:ReactNode}) {
  return <label className="field"><span>{label}</span>{children}{hint&&<small>{hint}</small>}</label>;
}
function App() {
  const [config,setConfig]=useState<Configuration>(structuredClone(defaults));
  const [busy,setBusy]=useState(true),[error,setError]=useState(''),[page,setPage]=useState(0);
  const [progress,setProgress]=useState<Progress>({running:false,exitCode:null,action:'',events:[]});
  const [plan,setPlan]=useState(''),[reviewed,setReviewed]=useState(false);
  const csrf=useRef('');
  const change=(next:Configuration)=>{setConfig(next);setPlan('');setReviewed(false);};
  const property=<K extends keyof Configuration>(key:K,value:Configuration[K])=>change({...config,[key]:value});
  async function operation(action:string,input?:unknown,fingerprint?:string) {
    setBusy(true);setError('');
    setProgress({running:true,exitCode:null,action,events:[]});
    try {
      const response=await fetch('/api/setup/operations',{method:'POST',headers:{'Content-Type':'application/json','X-Setup-Csrf':csrf.current},body:JSON.stringify({action,input,fingerprint})});
      if(!response.ok) throw new Error((await response.json()).message??'Setup could not start.');
      while(true) {
        const read=await fetch('/api/setup/progress');
        if(!read.ok) throw new Error('Setup session expired. Reopen the graphical installer.');
        const value:Progress=await read.json();setProgress(value);
        if(!value.running) {
          if(value.exitCode!==0) throw new Error(value.events.findLast(e=>e.type==='Warning')?.message??'The operation stopped. Run gateway doctor for diagnostics.');
          if(action==='Inspect') {
            const data=value.events.find(e=>e.type==='Setup')?.data;
            if(data?.configuration) setConfig(data.configuration);
            else if(data?.account?.tenantId) setConfig(c=>({...c,tenantId:data.account.tenantId,subscriptionId:data.account.subscriptionId}));
          }
          if(action==='Plan') {setPlan(value.reviewedPlan??'');setReviewed(false);setPage(1);}
          return value;
        }
        await new Promise(resolve=>setTimeout(resolve,1000));
      }
    } finally {setBusy(false);}
  }
  const run=(action:string,input?:unknown,fingerprint?:string)=>void operation(action,input,fingerprint).catch(e=>setError(e.message));
  useEffect(()=>{void (async()=>{
    const response=await fetch('/api/setup/session');
    if(!response.ok) throw new Error('Open the one-time setup link from your terminal.');
    csrf.current=(await response.json()).token;
    await operation('Inspect');
  })().catch(e=>{setError(e.message);setBusy(false);});},[]);
  const saveAndPlan=()=>void (async()=>{await operation('Save',submission(config));await operation('Plan');})().catch(e=>setError(e.message));
  const data=progress.events.findLast(e=>e.type==='Setup')?.data;
  const complete=['Apply','Verify'].includes(progress.action)&&progress.exitCode===0&&!progress.running;
  const consoleUrl=progress.events.findLast(e=>e.type==='Result')?.data?.consoleUrl;
  return <FluentProvider theme={webLightTheme}><div className="layout">
    <aside><div className="brand"><span className="brand-icon">G</span>A365 Gateway</div><div className="eyebrow">INSTALLATION</div><h1>Your gateway.<br/>Your environment.</h1><p>Connect your agents to Microsoft protection services. Run the gateway on your own infrastructure.</p><nav aria-label="Setup stages"><button className={page===0?'active':''} disabled={busy} onClick={()=>setPage(0)}><span>01</span> Configure connections</button><button className={page===1?'active':''} disabled={busy} onClick={()=>setPage(1)}><span>02</span> Review & install</button></nav><div className="aside-note">Same engine, every interface.<br/>Terminal and graphical setup share validation, deployment and verification.</div></aside>
    <main><header><span className="pill">LOCAL SETUP</span><span className="muted">Runtime deployment · Microsoft product services</span></header>
      {error&&<div className="error" role="alert">{error}</div>}
      {page===0?<><div className="heading"><div className="eyebrow">01 / CONFIGURE</div><h2>A clear path to a running gateway</h2><p>Review each connection here. Setup will prepare identities, permissions and selected resources before starting the gateway.</p></div>
      <fieldset disabled={busy}>
      <section className="card"><div className="card-title"><span className="number">1</span><div><h3>Microsoft tenant & gateway</h3><p>Choose the directory and local endpoints for this installation.</p></div></div><div className="grid">
        <Field label="Microsoft tenant ID"><Input value={config.tenantId} onChange={(_,d)=>property('tenantId',d.value)} placeholder="Tenant GUID" /></Field>
        <Field label="Environment"><Select value={config.environment} onChange={(_,d)=>{const environment=d.value as Configuration['environment'];change({...config,environment,agent365:{...config.agent365,allowDevelopmentRegistryPreview:false,registryBetaAcknowledged:false}});}}><option value="dev">Development</option><option value="staging">Staging</option><option value="prod">Production</option></Select></Field>
        <Field label="Project name" hint="2–8 lowercase letters or numbers; start with a letter."><Input value={config.projectName} onChange={(_,d)=>change({...config,projectName:d.value,agent365:{...config.agent365,seedBlueprintName:`A365 Gateway ${d.value} ${config.environment}`}})} /></Field>
        <Field label="Seed blueprint name"><Input value={config.agent365.seedBlueprintName} onChange={(_,d)=>property('agent365',{...config.agent365,seedBlueprintName:d.value})}/></Field>
        <Field label="API port"><Input type="number" min={1} max={65535} value={String(config.runtime.apiHostPort)} onChange={(_,d)=>property('runtime',{...config.runtime,apiHostPort:Number(d.value)})}/></Field>
        <Field label="Console port"><Input type="number" min={1} max={65535} value={String(config.runtime.consoleHostPort)} onChange={(_,d)=>property('runtime',{...config.runtime,consoleHostPort:Number(d.value)})}/></Field>
      </div><div className="inline-actions"><Button onClick={()=>run('SignIn',{tenantId:config.tenantId})}>Sign in to Microsoft</Button><span className="muted">Authentication opens in Microsoft’s official browser flow.</span></div></section>
      <section className="card"><div className="card-title"><span className="number">2</span><div><h3>Content Safety · Prompt Shields</h3><p>Detect prompt attacks before your external model runs.</p></div></div><Checkbox checked={config.promptShield.enabled} onChange={(_,d)=>property('promptShield',{...config.promptShield,enabled:!!d.checked,costAndQuotaAcknowledged:false})} label="Provision Azure AI Content Safety"/>
        {config.promptShield.enabled&&<div className="reveal"><div className="grid"><Field label="Azure subscription ID"><Input value={config.subscriptionId??''} onChange={(_,d)=>property('subscriptionId',d.value)}/></Field><Field label="Azure region" hint="For example, koreacentral. Availability is checked during deployment."><Input value={config.location??''} onChange={(_,d)=>property('location',d.value)}/></Field><Field label="Resource group" hint="Use a new group or this installation’s own existing group."><Input value={config.resourceGroupName??''} onChange={(_,d)=>property('resourceGroupName',d.value)}/></Field><Field label="Service tier"><Select value={config.promptShield.skuName} onChange={(_,d)=>property('promptShield',{...config.promptShield,skuName:d.value as 'F0'|'S0',costAndQuotaAcknowledged:false})}><option value="F0">F0 · Free, quota limited</option><option value="S0">S0 · Standard, paid usage</option></Select></Field></div><Checkbox checked={config.promptShield.costAndQuotaAcknowledged} onChange={(_,d)=>property('promptShield',{...config.promptShield,costAndQuotaAcknowledged:!!d.checked})} label="I understand the selected tier’s quota and Azure charges."/></div>}
      </section>
      <section className="card"><div className="card-title"><span className="number">3</span><div><h3>Microsoft Purview connection</h3><p>Bring existing DLP policies into the Console and assign them to individual agents.</p></div></div><Checkbox checked={config.purview.enabled} onChange={(_,d)=>property('purview',{...config.purview,enabled:!!d.checked,authorityRequirementsAcknowledged:false})} label="Set up Purview during this installation"/>
        {config.purview.enabled&&<div className="reveal notice"><p>Setup creates a dedicated application, a non-exportable certificate in this Windows account, and a DLP management role group. It verifies access to your existing policy catalog. Keep this Windows account available to run the catalog service.</p><p>Policies, rules and classifiers remain managed in Purview. Agent runtime permissions are checked separately during registration.</p><Checkbox checked={config.purview.authorityRequirementsAcknowledged} onChange={(_,d)=>property('purview',{...config.purview,authorityRequirementsAcknowledged:!!d.checked})} label="Authorize the dedicated identity, certificate and DLP management permissions."/></div>}
      </section>
      <section className="card"><div className="card-title"><span className="number">4</span><div><h3>Agent 365 registration</h3><p>Review manager authority for the tenant before creating the seed blueprint.</p></div></div><Field label="Reviewed Microsoft manager application IDs" hint="Enter independently reviewed GUIDs, separated by commas. See the bootstrap guide for the Microsoft source to verify."><Input value={config.agent365.reviewedManagerApplicationIds.join(', ')} onChange={(_,d)=>property('agent365',{...config.agent365,reviewedManagerApplicationIds:d.value.split(',').map(s=>s.trim())})}/></Field>
        {config.environment==='dev'?<><Checkbox checked={config.agent365.allowDevelopmentRegistryPreview} onChange={(_,d)=>property('agent365',{...config.agent365,allowDevelopmentRegistryPreview:!!d.checked,registryBetaAcknowledged:false})} label="Enable development agent registration using Registry preview"/>{config.agent365.allowDevelopmentRegistryPreview&&<Checkbox checked={config.agent365.registryBetaAcknowledged} onChange={(_,d)=>property('agent365',{...config.agent365,registryBetaAcknowledged:!!d.checked})} label="I acknowledge that Registry preview is unsupported for production."/>}</>:<p className="notice">Registry preview remains disabled in staging and production.</p>}
      </section></fieldset><footer><Button disabled={busy} onClick={()=>run('Doctor')}>Check prerequisites</Button><Button appearance="primary" size="large" disabled={busy} onClick={saveAndPlan}>Save settings & review plan →</Button></footer></>:
      <><div className="heading"><div className="eyebrow">02 / REVIEW & INSTALL</div><h2>{complete?'Your gateway is running':'Review before installation'}</h2><p>Setup uses the same reviewed plan and resource ownership checks as the terminal installer.</p></div><section className="card"><h3>{config.projectName} · {config.environment}</h3><dl><dt>Tenant</dt><dd>{config.tenantId}</dd><dt>Local services</dt><dd>PostgreSQL, RabbitMQ, Vault, S3, API, worker and Console</dd><dt>Content Safety</dt><dd>{config.promptShield.enabled?`${config.promptShield.skuName} · ${config.location} · ${config.resourceGroupName}`:'Not selected'}</dd><dt>Purview</dt><dd>{config.purview.enabled?'Dedicated certificate identity, DLP management role group and catalog verification':'Not selected'}</dd><dt>Registry preview</dt><dd>{config.agent365.allowDevelopmentRegistryPreview?'Enabled for development':'Disabled'}</dd></dl><p className="notice">Existing resources must match this installation’s ownership. Setup preserves checkpoints and stops if it cannot confirm a resource or credential.</p>{plan&&<details><summary>Reviewed plan identifier</summary><code>{plan}</code></details>}<Checkbox disabled={busy||!plan} checked={reviewed} onChange={(_,d)=>setReviewed(!!d.checked)} label="I reviewed these settings and authorize this installation’s resource and permission changes."/><div className="inline-actions"><Button disabled={busy} onClick={()=>setPage(0)}>Edit settings</Button><Button appearance="primary" disabled={busy||!plan||!reviewed} onClick={()=>run('Apply',undefined,plan)}>Install gateway</Button><Button disabled={busy} onClick={()=>run('Verify')}>Verify installation</Button>{complete&&typeof consoleUrl==='string'&&/^http:\/\/127\.0\.0\.1:\d+\/$/.test(consoleUrl)&&<a href={consoleUrl} target="_blank" rel="noreferrer">Open Console ↗</a>}</div></section></>}
      {(busy||progress.events.length>0)&&<section className="card progress" aria-live="polite"><div className="card-title">{busy&&<Spinner size="tiny"/>}<h3>{busy?`${progress.action||'Loading'} in progress`:progress.exitCode===0?'Completed':'Setup activity'}</h3></div>{progress.events.filter(e=>e.message).slice(-14).map((event,index)=><div className={`event ${event.type}`} key={index}><span>{event.type==='PhaseCompleted'?'✓':event.type==='Warning'?'!':'·'}</span>{event.message}</div>)}{data?.checks?.map((check:any,index:number)=><div className="event" key={index}><strong>{check.status}</strong> {check.name} — {check.value}{check.status==='Fail'&&<span>{check.remediation}</span>}</div>)}</section>}
    </main></div></FluentProvider>;
}
createRoot(document.getElementById('root')!).render(<App/>);
