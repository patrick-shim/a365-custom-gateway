/* M2 design fixture. All records are synthetic and live only in this page.
   No fetch, provider transport, authentication, storage, analytics or real keys. */
'use strict';
const $ = (q, root = document) => root.querySelector(q);
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]));
const badge = (label, tone = '') => `<span class="badge ${tone}">${esc(label)}</span>`;
const link = (route, label, primary = false) => `<a class="button${primary ? ' primary' : ''}" href="#${route}">${esc(label)}</a>`;
const button = (action, label, kind = '', attrs = '') => `<button type="button" data-action="${action}" class="${kind}" ${attrs}>${esc(label)}</button>`;
const notice = (title, body, tone = '', action = '') => `<div class="notice ${tone}" ${tone === 'error' ? 'role="alert"' : 'role="note"'}><span class="notice-icon" aria-hidden="true">${tone === 'success' ? '✓' : 'i'}</span><div><strong>${title}</strong><p>${body}</p>${action ? `<div class="actions">${action}</div>` : ''}</div></div>`;
const heading = (eyebrow, title, description, actions = '') => `<div class="page-heading"><div><div class="eyebrow">${eyebrow}</div><h1 tabindex="-1">${title}</h1><p>${description}</p></div>${actions ? `<div class="actions">${actions}</div>` : ''}</div>`;
const crumbs = (parent, title) => `<div class="breadcrumbs"><a href="#${parent}">${parent === '/agents' ? 'Agents' : parent === '/settings' ? 'Settings' : 'Getting started'}</a><span aria-hidden="true">/</span><span>${title}</span></div>`;
const card = (title, body, caption = '', extra = '') => `<section class="card"><div class="card-head"><div><h2>${title}</h2>${caption ? `<p>${caption}</p>` : ''}</div>${extra}</div><div class="card-body">${body}</div></section>`;
const empty = (title, body, action = '') => `<section class="card"><div class="empty-state"><div class="empty-icon" aria-hidden="true">◇</div><h2>${title}</h2><p>${body}</p>${action}</div></section>`;
let app, dialogAction, returnFocus, toastTimer, connectionTimer;
const names = ['Research assistant', 'Support companion', 'Finance analyst', 'Knowledge assistant', 'Service planner', 'Document reviewer', 'Travel assistant'];
const syntheticCompanionResult = 'A365GW_CONNECTION_RESULT:SYNTHETIC-DESIGN-ONLY';
const connectionInterval = 3000, connectionBudget = 5 * 60 * 1000;
function profileFixture(id, blueprint, mode) {
  return {
    id, blueprint, mode, revision:1, runtime:'draft', receipt:null, operation:'complete', pending:null,
    blueprintId:id==='profile-contoso'?'11111111-1111-4111-8111-111111111111':'22222222-2222-4222-8222-222222222222',
    types:[
      {id:'synthetic-sit-employee',name:'Fictional employee identifier',selected:true,minCount:1,maxCount:5,minConfidence:75,maxConfidence:100},
      {id:'synthetic-sit-project',name:'Fictional project code',selected:false,minCount:1,maxCount:-1,minConfidence:75,maxConfidence:100}
    ]
  };
}
function initial() {
  return {
    role:'Administrator', fixture:'success', route:'/dashboard', page:0, query:'', filter:'',
    savedKey:false, handoff:false, handoffReturn:'/operations/current', operation:'waiting',
    installer:'review', keys:{}, profileId:'', routeQuery:'', policyDraft:null, policyReviewed:false, classifierQuery:'',
    profiles:[profileFixture('profile-other','Other assistants','SimulationWithTips'),profileFixture('profile-contoso','Contoso assistants','SimulationWithoutTips')],
    connection:'connected', connectionReadback:'connected', connectionContextReadback:null, inventory:'current', inventoryGeneration:'synthetic-inventory-007',
    connectionId:'UX-DEMO-CONNECTION-021', previousConnectionId:null, connectionSubmissions:0,
    connectionCompleted:true, connectionValidUntil:Date.now()+15*60*1000, connectionVerifiedAt:Date.now(), launchExpiresAt:Date.now()+15*60*1000,
    observation:observationFixture(), policyWrites:0, sampleSubmissions:0, agentFeatureWrites:0,
    selectedAgent:'agent-001', newAgent:null, disabled:new Set(), deleted:new Set(), defaults:{agent365:true,monitor:false},
    draft:{name:'',externalId:'agent-demo-144',blueprint:'existing',blueprintName:'',shield:false,purview:false,agent365:true,azureMonitor:false},
    agents:Array.from({length:143}, (_, i) => ({
      id:`agent-${String(i+1).padStart(3,'0')}`,
      name:`${names[i % names.length]}${i < 7 ? '' : ` ${Math.floor(i/7)+1}`}`,
      externalId:`contoso-agent-${String(i+1).padStart(3,'0')}`,
      status:i === 1 ? 'Action required' : i % 13 === 0 && i > 0 ? 'Disabled' : 'Active',
      blueprint:[0,2,5].includes(i)?'Contoso assistants':'Other assistants',
      shield:i % 3 === 0, purview:i % 4 === 0 ? 'Simulation' : 'Off'
    }))
  };
}
const isAdmin = () => app.role === 'Administrator';
const canOperate = () => ['Administrator','Operator'].includes(app.role);
const canAudit = () => ['Administrator','Auditor'].includes(app.role);
function announce(text) { $('#announcement').textContent = ''; requestAnimationFrame(() => { $('#announcement').textContent = text; }); }
function toast(text) { clearTimeout(toastTimer); $('#toast').textContent=text; $('#toast').hidden=false; announce(text); toastTimer=setTimeout(() => { $('#toast').hidden=true; }, 3300); }
function openDialog(title, body, label, action, options={}) {
  returnFocus=document.activeElement;
  dialogAction=action;
  $('#dialog-content').innerHTML=`<div class="dialog-head"><h2 id="dialog-title">${title}</h2><button type="button" class="dialog-close" data-action="dialog-close" aria-label="Close dialog">×</button></div><div class="dialog-body">${body}</div><div class="dialog-footer">${button('dialog-close',options.cancel || 'Cancel')}${button('dialog-confirm',label,options.danger ? 'danger' : 'primary',options.disabled ? 'disabled' : '')}</div>`;
  $('#dialog').showModal();
  $('#dialog .dialog-close').focus();
}
function closeDialog() { $('#dialog').close(); dialogAction=null; if(returnFocus?.isConnected) returnFocus.focus(); }
function go(route, agentId) {
  if(app.handoff && !app.savedKey && route !== '/handoff') {
    openDialog('Leave without saving the key?', '<p>This key is shown once. If you leave now, issue a replacement from the agent’s details before connecting your application.</p>', 'Leave and hide key', () => { app.handoff=false;keyState().lost=true;if(agentId)app.selectedAgent=agentId;closeDialog();navigate(route); }, {cancel:'Stay and save key'});
    return;
  }
  if(app.handoff && route !== '/handoff') app.handoff=false;
  if(agentId)app.selectedAgent=agentId;
  navigate(route);
}
function navigate(route, focus=true) {
  const [pathname, query=''] = route.split('?');
  const profileId = new URLSearchParams(query).get('profile') || '';
  const changed = pathname!==app.route || profileId!==app.profileId;
  app.route=pathname;app.routeQuery=query;app.profileId=profileId;
  if(changed || !app.policyDraft) {
    const profile=currentProfile();
    app.policyDraft=profile?{mode:profile.mode,types:structuredClone(profile.types)}:null;
    app.classifierQuery='';
  }
  history.replaceState(null,'',`#${pathname}${query?'?'+query:''}`);render(focus);
}
function restricted(required='a Gateway Administrator') {
  return heading('Access', 'This task needs another role', 'Your current role can still view the agents available to you.') + empty('You don’t have access to this task', `Ask ${required} to complete it. Your role is ${esc(roleLabel())}.`,link('/agents','Back to agents'));
}
function roleLabel() { return app.role === 'SupportReader' ? 'Support reader' : app.role === 'Developer' ? 'External developer' : app.role; }
function loading(title) {return heading('Workspace',title,'Loading the latest Gateway state.')+`<section class="card" aria-busy="true"><div class="loading-lines"><div class="loading-label" role="status"><span class="spinner" aria-hidden="true"></span>Loading ${title.toLowerCase()}…</div><div class="skeleton short"></div><div class="skeleton"></div><div class="skeleton"></div><div class="skeleton"></div></div></section>`;}
function errorPage(title) {return heading('Workspace',title,'The latest state could not be loaded.')+notice(`We couldn’t load ${title.toLowerCase()}`, 'Your saved settings have not changed. Check again to load the latest information.', 'error',button('retry','Try again')+link('/agents','Back to agents'))+`<details><summary>Support details</summary><p>Reference: UX-DEMO-READ-001. Share this reference with your Gateway administrator.</p></details>`;}
function currentAgent() {return (app.selectedAgent==='agent-new' ? app.newAgent : null) || app.agents.find(a=>a.id===app.selectedAgent) || app.agents[0];}
function keyState(){const id=currentAgent().id;return app.keys[id]??(app.keys[id]={usable:1,lost:false,issued:1});}
function currentProfile(){return app.profiles.find(profile=>profile.id===app.profileId);}
function registrationProfile(){return app.profiles.find(profile=>profile.id==='profile-contoso');}
function profileForAgent(agent){return app.profiles.find(profile=>profile.blueprint===agent.blueprint);}
function profileRoute(task, profile=currentProfile()){return `/settings/${task}?profile=${encodeURIComponent(profile.id)}`;}
function modeLabel(mode){return {Enforce:'Enforce',SimulationWithTips:'Simulation with tips',SimulationWithoutTips:'Simulation without tips',Disabled:'Off'}[mode] || 'Status unknown';}
function connectionCurrent(){return app.connection==='connected'&&app.inventory==='current'&&Date.now()<app.connectionValidUntil;}
function currentBehavior(profile){
  const receipt=profile?.receipt;
  return Boolean(profile&&profile.operation==='complete'&&profile.runtime==='complete'&&profile.mode==='Enforce'&&connectionCurrent()&&
    receipt?.verified&&receipt.profileId===profile.id&&receipt.revision===profile.revision&&
    receipt.scope===profile.blueprintId&&receipt.inventoryGeneration===app.inventoryGeneration&&Date.now()<receipt.validUntil);
}
function purviewState(agent) {
  if(agent.purview==='Off' || agent.purview==='Configuration pending')return agent.purview;
  const profile=profileForAgent(agent);
  if(!profile)return 'Status unknown';
  if(profile.mode==='Disabled')return 'Off';
  if(!connectionCurrent())return 'Verification expired';
  if(profile.mode!=='Enforce')return 'Simulation';
  return currentBehavior(profile)&&agent.status==='Active'?'Enforcing':'Configured';
}
function sharedAgents(profile=registrationProfile()){return [...app.agents,...(app.newAgent?[app.newAgent]:[])].filter(a=>a.blueprint===profile.blueprint&&!app.deleted.has(a.id));}
function selectedTypesReview(types=app.policyDraft.types) {
  return types.filter(t=>t.selected).map(t=>`<div><dt>${esc(t.name)} · ${esc(t.id)}</dt><dd>Minimum matches: ${t.minCount} · maximum matches: ${t.maxCount===-1?'Any':t.maxCount} · confidence ${t.minConfidence}–${t.maxConfidence}</dd></div>`).join('');
}
function classifierEditor() {
  const types=app.policyDraft.types, query=app.classifierQuery.trim().toLowerCase();
  const choices=types.map((t,i)=>`<label class="check-line classifier-choice" data-classifier="${esc((t.name+' '+t.id).toLowerCase())}"${(t.name+' '+t.id).toLowerCase().includes(query)?'':' hidden'}><input id="sit-${i}" data-type-index="${i}" data-type-field="selected" type="checkbox" ${t.selected?'checked':''}><span>${esc(t.name)}<small>${esc(t.id)} · synthetic current inventory</small></span></label>`).join('');
  const thresholds=types.map((t,i)=>{
    if(!t.selected)return '';
    const fields=[['minCount','Minimum matches',1,null],['maxCount','Maximum matches',null,null],['minConfidence','Minimum confidence',1,100],['maxConfidence','Maximum confidence',1,100]];
    const inputs=fields.map(([field,label,min,max])=>{
      const unlimited=field==='maxCount';
      const value=unlimited&&t[field]===-1?'Any':t[field];
      const constraints=unlimited?'pattern="([Aa][Nn][Yy]|[1-9][0-9]*)"':`min="${min}" step="1" ${max?'max="'+max+'"':''}`;
      return `<label for="sit-${i}-${field}">${label}<input id="sit-${i}-${field}" data-type-index="${i}" data-type-field="${field}" type="${unlimited?'text':'number'}" value="${value}" ${constraints} required>${unlimited?'<span class="help">Enter a count or Any for no maximum.</span>':''}</label>`;
    }).join('');
    return `<section class="sample-card"><h4>${esc(t.name)}</h4><div class="form-grid">${inputs}</div></section>`;
  }).join('');
  return `<fieldset class="classifier-selection"><legend>1. Choose sensitive information types</legend><p class="help">A sensitive information type (SIT) is a definition that recognizes a kind of data. Choose every type this shared policy should check. Any selected type may match (OR).</p><label for="policy-classifier-search">Search available types<input id="policy-classifier-search" type="search" value="${esc(app.classifierQuery)}"></label>${choices}<p id="classifier-search-count" class="help" role="status">${types.filter(t=>(t.name+' '+t.id).toLowerCase().includes(query)).length} of ${types.length} available types shown.</p></fieldset><h3>2. Adjust selected-type thresholds (${types.filter(t=>t.selected).length})</h3><p class="help">New types start at 1 match, Any maximum, and confidence 75 to 100. Confidence is the classifier's reported matching level, not a promise of accuracy. Saved and edited values are preserved. Adjust these starting values before review.</p>${thresholds||'<p>Select at least one type above to configure its thresholds.</p>'}`;
}
function setupJourney(current) {
  if(!canOperate())return '';
  const profile=currentProfile();
  const steps=[['connection','Connect tenant','Verify access and find existing data types'],['policy','Set shared policy','Choose a blueprint, data types and mode'],['runtime','Test behavior','Required for Enforce; optional diagnostics for simulation'],['agents','Review agent choices','Choose Purview On or Off for each agent']];
  return `<section class="setup-navigation" aria-labelledby="setup-heading"><h2 id="setup-heading">Purview setup: follow these steps</h2><p id="setup-help">These are setup steps, not interchangeable settings tabs. Revisit an allowed step without undoing saved work. The highlight is your location, not proof of protection. Off is a valid finished choice.</p><nav aria-label="Purview setup steps" aria-describedby="setup-help"><ol class="setup-steps">${steps.map(([task,label,help],index)=>{
    const body=`<span class="setup-step-number" aria-hidden="true">${index+1}</span><span><strong>${label}</strong><small>${task==='runtime'&&!isAdmin()?'A Gateway Administrator approves this step':help}</small></span>`;
    const route=task==='agents'?'/agents':profile&&['policy','runtime'].includes(task)?profileRoute(task,profile):'/settings/'+task;
    return `<li>${task==='runtime'&&!isAdmin()?'<span>'+body+'</span>':`<a href="#${route}"${current===task?' aria-current="step"':''}>${body}</a>`}</li>`;
  }).join('')}</ol></nav><nav class="other-protection-tools" aria-label="Other protection tasks"><a href="#/settings">Protection overview</a>${isAdmin()?'<a href="#/settings/defaults">Registration defaults</a>':''}</nav><p class="help">Collection is optional and separate, not an extra DLP setup step. This prototype does not perform collection changes.</p></section>`;
}
function outcome(title, happened, why, remains, next, action='', busy=false) {
  return `<section class="card outcome-panel" aria-labelledby="outcome-heading" aria-busy="${busy}"><div class="card-head"><h2 id="outcome-heading">${title}</h2>${busy?'<span class="activity-cue"><span class="spinner" aria-hidden="true"></span>Reading saved status; no progress percentage is available.</span>':''}</div><dl class="outcome-grid">
    <div><dt>What happened</dt><dd>${happened}</dd></div>
    <div><dt>Why this matters</dt><dd>${why}</dd></div>
    <div><dt>What remains</dt><dd>${remains}</dd></div>
    <div><dt>Next step</dt><dd>${next}${action?`<div class="actions">${action}</div>`:''}</dd></div>
  </dl></section>`;
}
function technicalDetails(reference, state, steps) {
  return `<details class="technical-details" id="technical-operation"><summary>Technical operation details</summary>
    <p>Operation reference: <code>${esc(reference)}</code> · ${badge(state)}. Times are UTC; all records here are synthetic.</p>
    <ol class="steps">${steps.map(([label,status,description])=>`<li class="${status==='Completed'?'done':''}"><span class="step-marker" aria-hidden="true">${status==='Completed'?'✓':'–'}</span><div><h3>${esc(label)}</h3><p>${badge(status,status==='Failed'?'bad':'')} ${esc(description)}</p></div></li>`).join('')}</ol>
    <p><strong>Skipped means not run, not passed.</strong> Only the checks actually completed support this operation's outcome. It does not prove DLP blocking or telemetry delivery.</p>
  </details>`;
}
function stopConnectionObservation() {
  clearTimeout(connectionTimer);connectionTimer=null;
}
function observationFixture(stopReason=null) {
  return {expires:0,stopped:!!stopReason,stopReason,reads:0,lastRead:null,lastCheckedAt:null,contextReads:0,lastContextRead:null};
}
function connectionContextFixture() {
  return {connectionCompleted:app.connectionCompleted,inventory:app.inventory,inventoryGeneration:app.inventoryGeneration,connectionVerifiedAt:app.connectionVerifiedAt,connectionValidUntil:app.connectionValidUntil};
}
function reloadSyntheticConnectionContext() {
  app.observation.contextReads++;app.observation.lastContextRead=app.connectionId;
  Object.assign(app,app.connectionContextReadback||connectionContextFixture());
}
function observedConnectionState(){
  const state=app.fixture==='empty'?'waiting':app.connection;
  if(state==='waiting'&&Date.now()>=app.launchExpiresAt)return 'launch-expired';
  return state==='connected'&&!connectionCurrent()?'expired':state;
}
function observationText() {
  const status=app.observation.stopped
    ? `${app.observation.stopReason==='deadline'?'Automatic updates stopped after 5 minutes.':'You stopped automatic updates.'} The original operation may still be running. Resume automatic updates to check it without submitting again.`
    : `Automatic status checks every 3 seconds, for at most 5 minutes. GET-only local fixture reads: ${app.observation.reads}. No result is submitted again.`;
  return status+(app.observation.lastCheckedAt?` Last successful check (UTC): ${new Date(app.observation.lastCheckedAt).toISOString()}.`:' No successful status read in this observation session yet.');
}
function readSyntheticConnection() {
  // This is an in-memory GET fixture, never an HTTP or provider transport.
  app.observation.reads++;app.observation.lastRead=app.connectionId;
  const result=app.connectionReadback;
  if(!['unknown','read-error'].includes(result))app.observation.lastCheckedAt=Date.now();
  if(result!=='pending') {
    app.connection=result;
    reloadSyntheticConnectionContext();
    stopConnectionObservation();app.observation.expires=0;render();
    announce(result==='connected'&&connectionCurrent()?'Purview connection verified. Continue to shared policies when ready.':'Connection status updated. Review the outcome and safe next step.');
  } else {
    const status=$('#connection-observation');
    if(status){status.textContent=observationText();status.dataset.readCount=String(app.observation.reads);}
  }
}
function syncConnectionObservation() {
  if(app.route!=='/settings/connection'||!canOperate()||app.fixture!=='success'||app.connection!=='pending'||app.observation.stopped) {
    stopConnectionObservation();return;
  }
  if(connectionTimer)return;
  if(!app.observation.expires)app.observation.expires=Date.now()+connectionBudget;
  connectionTimer=setTimeout(()=>{
    connectionTimer=null;
    if(Date.now()>=app.observation.expires) {
      app.observation.stopped=true;app.observation.stopReason='deadline';render();announce('Automatic connection updates stopped. Resume automatic updates when ready.');return;
    }
    readSyntheticConnection();syncConnectionObservation();
  },Math.min(connectionInterval,Math.max(0,app.observation.expires-Date.now())));
}
function chooseConnectionFixture(value) {
  stopConnectionObservation();
  app.fixture='success';app.connection=value==='stopped'?'pending':value==='expired'?'connected':value;
  app.connectionReadback=app.connection==='pending'?'pending':app.connection;
  app.observation=observationFixture(value==='stopped'?'deadline':null);
  app.connectionCompleted=['connected','expired'].includes(value);
  app.inventory=value==='expired'?'expired':'current';
  app.connectionValidUntil=Date.now()+(value==='expired'?-1:15*60*1000);
  app.connectionContextReadback=connectionContextFixture();
  if(value==='waiting'||value==='launch-expired')app.launchExpiresAt=Date.now()+(value==='launch-expired'?-1:15*60*1000);
  render(true);
}
function profilePicker(task) {
  const profile=currentProfile();
  const selector=`<label for="profile-select">Choose a shared blueprint<select id="profile-select" data-task="${task}"><option value="">Choose a blueprint and its profile</option>${app.profiles.map(p=>`<option value="${esc(p.id)}"${p===profile?' selected':''}>${esc(p.blueprint)} · ${esc(p.id)}</option>`).join('')}</select><span class="help">A blueprint groups agent identities. Its policy is shared by every agent using it; each agent still chooses whether to use Purview.</span></label>`;
  if(app.profileId&&!profile)return heading('Shared protection','Shared policy not found','The requested profile is missing or is no longer available.')+
    outcome('Choose a valid policy','The requested profile could not be found. No other profile was selected.','A different profile could affect a different group of agents.','No configuration or test was sent.','Return to the permitted profile list or ask an administrator.',link(`/settings/${task}`,'Choose another shared policy',true)+link('/agents','Back to agents'));
  return heading('Microsoft Purview',task==='policy'?'Choose a shared blueprint policy':'Choose the policy to test','Continue with the exact shared profile, not the first returned record.')+
    outcome('Choose the shared scope','No policy has been changed by opening this page.','The blueprint determines which agents share the classifiers, thresholds and mode.','Review the policy and any required behavior tests, then explicitly choose an agent’s protection. Collection is optional and separate.','Select the blueprint below. Off and simulation are valid choices.')+
    card('Shared profiles',selector);
}
function render(focus=false) {
  const oldFocus=document.activeElement;
  const focusId=oldFocus?.id, focusAction=oldFocus?.dataset?.action;
  $('#fixture-role').value=app.role;$('#fixture-state').value=app.fixture;$('#role-caption').textContent=roleLabel();
  const nav=[['/setup','◇','Getting started'],['/dashboard','⌂','Overview'],['/agents','◎','Agents'],['/settings','⚙','Settings']];
  $('#nav').innerHTML=app.role==='Developer' ? `<span class="nav-label">INTEGRATION GUIDE</span><a class="nav-link" href="#/integration" aria-current="page"><span class="nav-icon" aria-hidden="true">↗</span>Connect an agent</a>` : `<span class="nav-label">WORKSPACE</span>${nav.map(([r,i,l])=>`<a class="nav-link${r==='/settings'?' nav-section':''}" href="#${r}"${app.route===r || (r==='/agents' && (app.route.startsWith('/agents/') || app.route.startsWith('/operations/') || app.route==='/handoff')) || (r==='/settings'&&app.route.startsWith('/settings/'))?' aria-current="page"':''}><span class="nav-icon" aria-hidden="true">${i}</span>${l}</a>`).join('')}`;
  let html;
  const adminRoute=['/agents/register','/handoff','/settings/runtime','/settings/defaults'].includes(app.route);
  const protectionRead=['/settings/policy','/settings/connection'].includes(app.route);
  if(app.role==='Developer' && app.route!=='/integration') {app.route='/integration';app.routeQuery='';app.profileId='';history.replaceState(null,'','#/integration');}
  if(app.fixture==='restricted' || (adminRoute&&!isAdmin()) || (protectionRead&&!canOperate()) || (app.route.startsWith('/operations/')&&!canOperate())) html=restricted(app.route.startsWith('/operations/')||protectionRead?'a Gateway Administrator or Operator':'a Gateway Administrator');
  else if(app.fixture==='loading') html=loading(routeTitle());
  else if(app.fixture==='error'&&!['/agents/register','/operations/current','/settings/connection','/settings/policy','/settings/runtime','/installation'].includes(app.route)) html=errorPage(routeTitle());
  else {
    const views={'/dashboard':overview,'/setup':gettingStarted,'/agents':agents,'/agents/register':register,'/agents/detail':()=>agentDetails()+agentProtectionTask(),'/operations/current':operation,'/handoff':handoff,'/settings':settings,'/settings/policy':policy,'/settings/runtime':runtime,'/settings/connection':connection,'/settings/defaults':defaults,'/integration':integration,'/installation':installation};
    html=(views[app.route] || (()=>empty('This page isn’t available','Return to the Gateway overview to continue.',link('/dashboard','Open overview'))))();
  }
  $('#main').innerHTML=html;
  document.title=`${routeTitle()} · A365 Gateway prototype`;
  if(focus) { ($('#main h1') || $('#main')).focus(); window.scrollTo({top:0,behavior:'instant'}); }
  else if(oldFocus && !oldFocus.isConnected){
    const replacement=focusId?document.getElementById(focusId):focusAction?$(`[data-action="${focusAction}"]`):null;
    (replacement || $('#main h1') || $('#main')).focus();
  }
  syncConnectionObservation();
}
function routeTitle(){return {'/dashboard':'Overview','/setup':'Getting started','/agents':'Agents','/agents/register':'Register an agent','/agents/detail':'Agent details','/operations/current':'Agent setup','/handoff':'Save your connection details','/settings':'Settings','/settings/policy':'Shared policy','/settings/runtime':'Test policy behavior','/settings/connection':'Connect Microsoft Purview','/settings/defaults':'Registration defaults','/integration':'Connect your external agent','/installation':'Install your Gateway'}[app.route]||'Gateway';}
function overview(){
  const visible=app.fixture==='empty'?[]:[...(app.newAgent?[app.newAgent]:[]),...app.agents].filter(a=>!app.deleted.has(a.id));
  const count=visible.length, activeCount=visible.filter(a=>a.status==='Active').length;
  const attention=visible.filter(a=>a.status==='Action required'), task=attention[0];
  const title=!count?'Your Gateway is ready for its first agent':task?'One agent needs an administrator':'Your agents are connected';
  const description=!count?'Register an agent, save its connection details, then complete Agent 365 setup.':task?`${esc(task.name)} is waiting for its Agent 365 registration. Its identity and Gateway key are already prepared.`:'View your agents and their current registration and protection choices.';
  const taskAction=task&&canOperate()?`<a class="button primary" href="#/operations/current" data-agent="${task.id}">View setup task</a>`:link(count?'/agents':'/setup',count?'View agents':'Open getting started',true);
  const recent=count?`<ul class="link-list">${visible.slice(0,3).map(a=>`<li><a href="#/agents/detail" data-agent="${a.id}">${esc(a.name)}</a><p class="small-text no-margin">${esc(a.status)} · Prompt Shields ${a.shield?'on':'off'} · Purview ${esc(purviewState(a).toLowerCase())}</p></li>`).join('')}<li><a href="#/agents">Browse all ${count} agents →</a></li></ul>`:'<p>No agent activity yet. Your first registration will appear here.</p>';
  return heading('Your workspace','A clear view of your agents','Register external agents, follow their setup, and choose the protections they use.',isAdmin()?link('/agents/register','Register agent',true):'')+
    `<section class="hero"><div><div class="eyebrow">${count?'YOUR NEXT STEP':'START HERE'}</div><h2>${title}</h2><p>${description}</p><div class="actions">${taskAction}${count?link('/setup','Getting started'):''}</div></div><div class="hero-art" aria-hidden="true">↗</div></section>`+
    `<div class="metrics"><section class="metric"><small>Registered agents</small><strong>${count}</strong><p>Across the whole Gateway</p></section><section class="metric"><small>Active registrations</small><strong>${activeCount}</strong><p>Enabled to use the Gateway</p></section><section class="metric"><small>Action required</small><strong>${attention.length}</strong><p>Waiting for an administrator</p></section></div>`+
    `<div class="grid-two">${card('Keep work moving',recent,'Your agents and their next steps')}${card('Protection is a choice',`<p class="small-text">Each agent can use Prompt Shields, Microsoft Purview, both, or neither.</p><dl class="summary-list"><div><dt>Prompt Shields</dt><dd>${badge('Installed','good')} Choose usage per agent</dd></div><div><dt>Microsoft Purview</dt><dd>${badge('Installed','good')} Configure shared blueprint policies</dd></div></dl><div class="spacer">${link('/settings','View protection settings')}</div>`,'Shared services, individual agent choices')}</div><p class="aside-note">Active describes the Gateway registration. Protection readiness and downstream delivery are reported separately.</p>`;
}
function gettingStarted(){return heading('Getting started','From a ready Gateway to a connected agent','Follow the steps that apply to your role. Optional protections can be configured when you need them.')+`<div class="grid-two"><section class="card"><div class="card-head"><div><h2>Connect your first agent</h2><p>Save connection details before completing Agent 365 setup.</p></div></div><ol class="task-list"><li><span class="task-number">1</span><div class="task-content"><h3>Choose the agent and its blueprint</h3><p>A reusable blueprint groups related agent identities. Each agent still receives its own identity and key.</p>${isAdmin()?link('/agents/register','Register agent',true):'<span class="badge">Administrator task</span>'}</div></li><li><span class="task-number">2</span><div class="task-content"><h3>Save the one-time Gateway key</h3><p>Give the external developer the API endpoint, external agent ID, and a key stored through your secret manager.</p></div></li><li><span class="task-number">3</span><div class="task-content"><h3>Complete Agent 365 setup</h3><p>A Gateway Administrator completes the Registry step. The Gateway then checks the final identity mapping.</p>${canOperate()?`<a href="#/operations/current" data-agent="agent-002">View an agent setup task →</a>`:''}</div></li><li><span class="task-number">4</span><div class="task-content"><h3>Connect and send an interaction</h3><p>Follow the integration guide. Evaluate every prompt before model generation, even when optional protections are off.</p><a href="#/integration">Open the developer guide →</a></div></li></ol></section><div class="stack">${card('Add protection when needed',`<p class="small-text">Prompt Shields detects prompt attacks. Microsoft Purview applies your organization’s data policy. Both are optional per agent.</p>${link('/settings','Explore protection settings')}`)}${card('Looking for installation?',`<p class="small-text">Installation prepares the Gateway itself. This getting-started page belongs to the hosted Admin UI after installation.</p>${link('/installation','View installation flow')}`)}</div></div>`;}
function agents(){
  let rows=app.fixture==='empty'?[]:[...(app.newAgent?[app.newAgent]:[]),...app.agents].filter(a=>!app.deleted.has(a.id));
  rows=rows.map(a=>({...a,status:app.disabled.has(a.id)?'Disabled':a.status}));
  const total=rows.length;
  rows=rows.filter(a=>(!app.query||`${a.name} ${a.externalId}`.toLowerCase().includes(app.query.toLowerCase()))&&(!app.filter||a.status===app.filter));
  const start=app.page*10;if(start>=rows.length&&app.page>0)app.page=0;const offset=app.page*10, page=rows.slice(offset,offset+10);
  return heading('Agent registry','Agents','Find an agent by name or external ID. View its setup, connection, and protection choices.',isAdmin()?link('/agents/register','Register agent',true):'')+`<section class="card"><form id="agent-search" class="filter-row"><label for="agent-query">Search agents<input id="agent-query" name="query" type="search" value="${esc(app.query)}" placeholder="Name or external agent ID"></label><label for="agent-status">Status<select id="agent-status" name="status"><option value="">All statuses</option>${['Active','Action required','Disabled'].map(x=>`<option${app.filter===x?' selected':''}>${x}</option>`).join('')}</select></label><div class="actions"><button type="submit" class="primary">Search</button>${button('clear-search','Clear','subtle')}</div></form><div class="result-summary" role="status"><span>${rows.length?`${offset+1}–${Math.min(offset+10,rows.length)} of ${rows.length} ${app.query||app.filter?'matching ':''}agents`:'No agents to show'}</span><span>${total} in Gateway</span></div>${page.length?`<div class="table-wrap"><table><caption class="sr-only">Agents matching the current filters</caption><thead><tr><th>Agent</th><th>Registration</th><th>Prompt Shields</th><th>Purview</th></tr></thead><tbody>${page.map(a=>`<tr><td data-label="Agent"><a href="#/agents/detail" data-agent="${a.id}">${esc(a.name)}</a><small>${esc(a.externalId)}</small></td><td data-label="Registration">${badge(a.status,a.status==='Active'?'good':a.status==='Action required'?'warn':'')}</td><td data-label="Prompt Shields">${badge(a.shield?'On':'Off',a.shield?'good':'')}</td><td data-label="Purview">${badge(purviewState(a),purviewState(a)==='Simulation'?'blue':'')}</td></tr>`).join('')}</tbody></table></div><div class="card-footer"><p>Page ${app.page+1} of ${Math.ceil(rows.length/10)} · 10 per page</p><div class="actions">${button('prev-page','Previous','',app.page===0?'disabled':'')}${button('next-page','Next','',offset+10>=rows.length?'disabled':'')}</div></div>`:`<div class="empty-state"><div class="empty-icon" aria-hidden="true">◎</div><h2>${app.query||app.filter?'No matching agents':'No agents registered yet'}</h2><p>${app.query||app.filter?'Try another name or external ID, or clear the filters.':'Register your first external agent to start its Gateway and Agent 365 setup.'}</p>${app.query||app.filter?button('clear-search','Clear filters'):isAdmin()?link('/agents/register','Register agent',true):'<p>A Gateway Administrator can register an agent.</p>'}</div>`}</section>`;
}
function register(){
  const d=app.draft;
  if(app.fixture==='error')return crumbs('/agents','Register')+heading('Registration','Registration result needs checking','The response was interrupted. A Gateway registration may already exist.')+notice('Check before submitting again','Search for the external agent ID. If it exists, open that registration and issue a replacement key if the original key was not received.','warning',link('/agents','Check agents',true))+card('Keep this reference',`<p>External agent ID: <code>${esc(d.externalId||'contoso-agent-144')}</code></p><p class="small-text">Reference: UX-DEMO-CREATE-001. Ask an administrator to check this reference if the registration cannot be found.</p><p class="small-text no-margin">No automatic resubmission is offered for an uncertain create result.</p>`);
  return crumbs('/agents','Register')+heading('New connection','Register an agent','Choose its identity, then decide which optional protections it should use.')+`<div class="grid-two"><form id="register-form" class="card"><section class="form-section"><div class="section-number">01 / AGENT</div><h2>Give your agent a name</h2><p class="small-text">Use a name people can recognize. Owner: Jordan Davis. Environment: Development. The generated external ID identifies this registration.</p><div class="form-grid"><label for="agent-name">Agent name<input id="agent-name" name="name" required maxlength="256" value="${esc(d.name)}" placeholder="e.g. Research assistant" autocomplete="off"></label><label for="external-id">External agent ID<input id="external-id" name="externalId" readonly required maxlength="128" pattern="[a-zA-Z0-9][a-zA-Z0-9._\\-]*" value="${esc(d.externalId)}" placeholder="e.g. research-assistant" aria-describedby="external-help" autocomplete="off"><span id="external-help" class="help">Generated once for this registration. Kept stable while you review.</span></label></div></section><section class="form-section"><div class="section-number">02 / IDENTITY</div><h2>Choose a reusable blueprint</h2><p class="small-text">Every agent receives a distinct child identity, even when it shares a blueprint.</p><fieldset><legend class="sr-only">Blueprint choice</legend><label class="choice"><input type="radio" name="blueprint" value="existing" ${d.blueprint==='existing'?'checked':''}><span>Use an existing blueprint<small>Reuse the identity group for related agents.</small></span></label><label class="choice"><input type="radio" name="blueprint" value="new" ${d.blueprint==='new'?'checked':''}><span>Create a reusable blueprint<small>Create a group that other agents can reuse later.</small></span></label></fieldset>${d.blueprint==='existing'?app.fixture==='empty'?notice('No reusable blueprints yet','Choose “Create a reusable blueprint” to continue.','',button('new-blueprint','Create a reusable blueprint')):`<label for="blueprint-select">Reusable blueprint<select id="blueprint-select" name="existingBlueprint"><option>Contoso assistants</option></select><span class="help">The Gateway rechecks this selection before provisioning.</span></label>`:`<label for="blueprint-name">Blueprint name<input id="blueprint-name" name="blueprintName" value="${esc(d.blueprintName)}" required maxlength="100" placeholder="e.g. Research assistants"><span class="help">The final application ID is assigned during setup.</span></label>`}</section><section class="form-section"><div class="section-number">03 / OPTIONAL FEATURES</div><h2>Choose what this agent uses</h2><p class="small-text">You can connect a core agent with both protections off.</p><label class="choice"><input type="checkbox" name="shield" ${d.shield?'checked':''}><span>Prompt Shields<small>Check prompts for attacks before model generation. Shared service: installed.</small></span></label><label class="choice"><input type="checkbox" name="purview" ${d.purview?'checked':''}><span>Microsoft Purview<small>Apply a data policy shared by agents using the same blueprint.</small></span></label>${d.purview?notice(d.blueprint==='new'?'Review the policy for the new blueprint':'Review the shared blueprint policy',d.blueprint==='new'?'Your confirmed choices wait for the new blueprint’s exact application ID. They do not protect the agent yet.':'A change to this policy affects every agent using this blueprint. Review the affected agents before continuing.','',button('review-registration-policy',app.policyReviewed?'Review policy again':'Review policy',app.policyReviewed?'':'primary')+(app.policyReviewed?badge('Reviewed','good'):'')):''}<div class="divider-line"></div><h3>Telemetry destinations</h3><label class="check-line"><input type="checkbox" name="agent365" ${d.agent365?'checked':''}><span>Send agent telemetry to Agent 365</span></label><label class="check-line"><input type="checkbox" name="azureMonitor" ${d.azureMonitor?'checked':''}><span>Also send telemetry to Azure Monitor</span></label><p class="help no-margin">Gateway service diagnostics are managed separately.</p></section><div class="form-actions"><a href="#/agents">Cancel</a><button class="primary" type="submit" ${app.fixture==='empty'&&d.blueprint==='existing'?'disabled':''}>Review registration</button></div></form><aside class="stack">${card('What happens next',`<ol class="steps"><li><span class="step-marker">1</span><div><h3>Save your connection details</h3><p>You’ll receive the API endpoint, external ID, and a one-time Gateway key.</p></div></li><li><span class="step-marker">2</span><div><h3>Finish Agent 365 setup</h3><p>A Gateway Administrator completes the Registry step.</p></div></li><li><span class="step-marker">3</span><div><h3>Connect the external agent</h3><p>Use the developer guide once the registration is Active.</p></div></li></ol>`)}${notice('Development preview','Agent 365 Registry is a beta dependency. This registration uses the development preview.','warning')}</aside></div>`;
}
function copyField(id,label,value){return `<label class="copy-label" for="${id}">${label}</label><div class="copy-row"><input id="${id}" readonly value="${esc(value)}" autocomplete="off" spellcheck="false"><button type="button" data-action="copy" data-copy="${id}" aria-label="Copy ${label.toLowerCase()}">Copy</button></div>`;}
function sampleCommand(id){return `# Bash example from the repository root.\n# The sample asks for the key without echoing it; the key is not a command argument.\ndotnet run --project src/ExternalAgent.Sample -- \\\n  --api-base-url https://gateway.example.invalid/ \\\n  --external-agent-id ${id} \\\n  --tenant-user-object-id 11111111-1111-4111-8111-111111111111 \\\n  --message "Hello through the Gateway"\n\n# Replace the synthetic endpoint and user ID before real use.\n# Always evaluate → validate the allow receipt → model once → submit.\n# The included sample uses a fixed-response model stub.`;}
function handoff(){
  if(!app.handoff)return heading('Connection details','This key is no longer available','The one-time key is not retained in the portal.')+empty('Need a new key?','Open the agent’s details to issue a replacement. Revoke a lost key when the replacement is installed.',link('/agents/detail','Open agent details',true));
  const a=currentAgent();return crumbs('/agents','Connection details')+heading(app.handoffReturn==='/agents/detail'?'Replacement issued':'Registration accepted','Save your connection details',app.handoffReturn==='/agents/detail'?'Store the replacement key, update your external agent, then revoke the old key.':'Your agent record is created. Save the key now, then follow Agent 365 setup.')+notice('This key is shown once','Store it in the external agent’s secret manager. Leaving this screen hides it permanently.','warning')+`<div class="grid-two">${card('Connect to this Gateway',`${copyField('handoff-endpoint','Gateway API endpoint','https://gateway.example.invalid/')}${copyField('handoff-id','External agent ID',a.externalId)}${copyField('handoff-key','One-time Gateway key',`gw_demo_not_valid_${currentAgent().id}_${keyState().issued}`)}<p class="help">Send the key in the Authorization header. Never put it in a URL. Example credential only.</p><details><summary>View a non-secret connection example</summary><pre id="handoff-sample">${esc(sampleCommand(a.externalId))}</pre>${button('copy','Copy sample command','', 'data-copy="handoff-sample"')}</details><label class="check-line"><input id="saved-key" type="checkbox" ${app.savedKey?'checked':''}><span>I have saved the key in a secret manager.</span></label><div class="actions">${button('continue-setup',app.handoffReturn==='/agents/detail'?'Return to agent':'Continue to agent setup','primary',!app.savedKey?'disabled':'')}</div>`)}<aside class="stack">${card('Keep these together',`<dl class="summary-list"><div><dt>Agent</dt><dd>${esc(a.name)}</dd></div><div><dt>Registration</dt><dd>${badge(a.status,a.status==='Active'?'good':'blue')}</dd></div><div><dt>Prompt Shields</dt><dd>${badge(a.shield?(a.status==='Active'?'On':'Requested on'):'Off',a.shield?'blue':'')}</dd></div><div><dt>Microsoft Purview</dt><dd>${badge(purviewState(a),purviewState(a)==='Off'?'':'blue')}</dd></div></dl><p class="aside-note">A key is available before the agent is Active. Follow setup before sending production traffic.</p>`)}${card('Lost the key?',`<p class="small-text no-margin">Issue a replacement from agent details, store it, update your external agent, then revoke the lost key. The original value cannot be recovered.</p>`)}</aside></div>`;
}
function operation(){
  const a=currentAgent(), unknown=app.fixture==='error'&&app.operation!=='active', active=!unknown&&a.status==='Active';
  if(app.fixture==='empty')return heading('Agent setup','No operation selected','Open an agent to view its setup history.')+empty('Choose an agent first','Setup tasks are linked to their registration.',link('/agents','Back to agents'));
  let task=active?notice('Agent setup is complete','The Gateway verified the identity mapping and marked this registration Active. You can now connect your external agent.','success',link('/integration','Open integration guide',true)):unknown?notice('The Registry result is not confirmed','The request may have succeeded. Check the existing registration before taking further action. A second create request will not be sent.','warning',isAdmin()?button('reconcile-registry','Check existing registration','primary'):'<span>A Gateway Administrator must check the result.</span>'):notice('Administrator action required','Finish this agent’s Agent 365 registration using your signed-in administrator session.','warning',isAdmin()?button('complete-registry','Complete Agent 365 registration','primary'):'<span>Ask a Gateway Administrator to complete this step. You can keep viewing progress.</span>');
  return crumbs('/agents','Agent setup')+heading('Agent setup',esc(a.name),active?'The Gateway registration is ready. Protection and delivery status remain separate.':'Follow the remaining identity setup. Keep the connection details in your secret manager.',link('/agents/detail','Back to agent'))+task+`<div class="grid-two">${card('Setup progress',`<div class="summary-inline summary-list"><div><dt>Progress</dt><dd>${active?'7 of 7 complete':'5 of 7 complete'}</dd></div><div><dt>Status</dt><dd>${badge(active?'Active':unknown?'Result unknown':'Action required',active?'good':'warn')}</dd></div></div><div class="progress-track ${active?'finished':''}" aria-hidden="true"><span></span></div><ol class="steps">${['Resolve reusable blueprint','Verify blueprint principal','Configure Gateway federation','Create the agent’s child identity','Assign Agent 365 observability access','Complete Agent 365 registration','Verify the final identity mapping'].map((s,i)=>`<li class="${active||i<5?'done':i===5?'current':''}"><span class="step-marker" aria-hidden="true">${active||i<5?'✓':i+1}</span><div><h3>${s}</h3><p>${active||i<5?'Completed':i===5?(unknown?'Check the existing registration. Do not create another.':'Waiting for a Gateway Administrator.'):'Starts after the Registry step is accepted.'}</p></div></li>`).join('')}</ol>`,'Progress belongs to this registration')}${card('Resume with context',`<dl class="summary-list"><div><dt>External agent ID</dt><dd>${esc(a.externalId)}</dd></div><div><dt>Blueprint</dt><dd>${esc(a.blueprint||'Contoso assistants')}</dd></div><div><dt>Operation reference</dt><dd>UX-DEMO-OP-144</dd></div></dl><p class="aside-note">You can close this page and reopen the task from the agent’s details. Completed identity steps are not repeated.</p>${button('refresh-operation','Refresh status')}<details><summary>What if sign-in needs attention?</summary><p>Complete the Microsoft Entra sign-in, consent, or MFA prompt. Then return to this same operation. The portal never asks you to paste a Microsoft access token.</p></details>`)}</div>`;
}
function agentDetails(){
  const a=currentAgent(), disabled=app.disabled.has(a.id)||a.status==='Disabled', status=disabled?'Disabled':a.status;
  return crumbs('/agents',esc(a.name))+heading('Agent details',esc(a.name),`External agent ID: ${esc(a.externalId)}`,canOperate()&&['Active','Disabled'].includes(status)?button('toggle-agent',disabled?'Enable agent':'Disable agent'):'')+(keyState().lost&&isAdmin()?notice('The original key is no longer available','Issue a replacement, update your external agent, and revoke the lost key.','warning',button('replace-key','Issue replacement key','primary')):'')+`<div class="grid-two"><div class="stack">${card('Registration',`<dl class="summary-list summary-inline"><div><dt>Gateway status</dt><dd>${badge(status,status==='Active'?'good':status==='Action required'?'warn':'')}</dd></div><div><dt>Environment</dt><dd>Development</dd></div><div><dt>Reusable blueprint</dt><dd>${esc(a.blueprint||'Contoso assistants')}</dd></div></dl><p class="aside-note">This agent has its own child identity and Gateway credential lifecycle.</p><div class="actions">${canOperate()?link('/operations/current','View setup operation'):''}${canAudit()?button('view-audit','View audit history'):''}</div>`)}${card('Protection choices',`<div class="grid-equal"><div><h3>Prompt Shields</h3>${badge(a.shield?'On':'Off',a.shield?'good':'')}<p class="aside-note">${a.shield?'Checks prompts before generation.':'This agent does not use prompt attack checks.'}</p></div><div><h3>Microsoft Purview</h3>${badge(purviewState(a),purviewState(a)==='Simulation'?'blue':'')}<p class="aside-note">${purviewState(a)==='Off'?(a.purview==='Off'?'No data policy is requested for this agent.':'The shared blueprint policy is off.'):purviewState(a)==='Simulation'?'Shared blueprint policy; simulation does not enforce blocking.':'Shared policy configuration is saved. Current enforcement evidence is required separately.'}</p></div></div>${isAdmin()?link('/settings','View protection settings'):''}`)}${isAdmin()?card('Gateway keys',`<p class="small-text">Key values are never displayed again. Credential metadata remains available to administrators.</p><dl class="summary-list summary-inline"><div><dt>Usable keys: ${keyState().usable}</dt><dd>${badge(keyState().lost?'Replacement needed':'Available',keyState().lost?'warn':'good')}</dd></div><div><dt>Key reference</dt><dd>demo-key-${esc(a.id)}</dd></div></dl><div class="actions spacer">${button('replace-key','Issue replacement key')}${button('revoke-key','Revoke key','danger')}</div>`):''}</div><aside class="stack">${card('Developer handoff',`<p class="small-text">Share the endpoint and external ID. Deliver keys through your organization’s secret manager.</p>${copyField('detail-endpoint','Gateway API endpoint','https://gateway.example.invalid/')}${link('/integration','Open integration guide')}`)}${isAdmin()?card('Remove from this Gateway',`<p class="small-text">Deleting the registration removes its Gateway access. It does not delete Microsoft Entra, Agent 365, or Purview resources.</p>${button('delete-agent','Delete Gateway registration','danger')}`):''}</aside></div>`;
}
function settings(){
  const zero=app.fixture==='empty';
  return heading('Administration','Settings','Manage shared services, then explicitly choose how each agent uses them.')+
    setupJourney('overview')+`
    <div class="grid-two"><section class="card"><div class="card-head"><div><h2>Protection tasks</h2><p>Optional for individual agents</p></div></div>
    <div class="protection-task"><span class="task-symbol" aria-hidden="true">◈</span><div><h3>Prompt Shields</h3><p>The shared service is installed. Turn usage on or off for each agent, independently of Purview.</p>${badge('Installed','good')}<div class="actions">${link('/agents','View agent choices')}</div></div></div>
    <div class="protection-task"><span class="task-symbol" aria-hidden="true">◇</span><div><h3>Connect Microsoft Purview</h3><p>${zero?'The optional capability is not installed in this Gateway. Agents with Purview off can continue normally.':!canOperate()?'Connection details require an Administrator or Operator.':connectionCurrent()?'Gateway app access and the classifier inventory are verified. This did not create a policy or enable an agent.':'Read the existing connection and its safe next step before another action.'}</p>${badge(zero?'Not installed':!canOperate()?'Installed':connectionCurrent()?'Connection verified':'Check connection',connectionCurrent()&&!zero&&canOperate()?'good':'')}${!zero&&canOperate()?`<div class="actions">${link('/settings/connection','Review connection')}</div>`:''}</div></div>
    ${!zero&&canOperate()?`<div class="protection-task"><span class="task-symbol" aria-hidden="true">≋</span><div><h3>Choose shared blueprint policies</h3><p>Choose the exact blueprint. Review classifiers, thresholds, mode and the impact on every agent using it.</p><div class="actions">${isAdmin()?link('/settings/policy','Manage shared policy'):button('policy-summary','View policy summary')}</div></div></div>
    <div class="protection-task"><span class="task-symbol" aria-hidden="true">✓</span><div><h3>Test policy behavior</h3><p>Enforce needs approved clean-negative and intended-classifier examples. Simulation diagnostics are optional; Off needs no runtime test.</p>${isAdmin()?`<div class="actions">${link('/settings/runtime','Choose a policy to test')}</div>`:'<p>A Gateway Administrator runs and views runtime tests.</p>'}</div></div>`:''}</section>
    <aside class="stack">${card('Keep the choices separate','<p>Connection verification, a saved policy and current enforcing behavior are different outcomes. Each agent still needs an explicit protection choice.</p><h3>Collection is optional</h3><p>Know Your Data collection is a separate tenant-wide choice, never a prerequisite to DLP. Telemetry delivery also needs separate evidence.</p>')}${notice('Core agents are complete with protections off','Unused optional features do not create an incomplete setup warning.')}</aside></div>`;
}
function policy() {
  const profile=currentProfile();
  if(!profile)return crumbs('/settings','Shared policy')+setupJourney('policy')+profilePicker('policy');
  const state=app.fixture==='error'?'read-error':profile.operation;
  const off=profile.mode==='Disabled', simulation=profile.mode.startsWith('Simulation'), ready=currentBehavior(profile);
  let title=off?'Policy saved; Purview is off':simulation?'Policy saved in simulation':ready?'Current policy behavior verified':'Policy saved; behavior is not verified';
  let happened=`The ${esc(modeLabel(profile.mode))} policy is saved for ${esc(profile.blueprint)}. Configuration readback is complete.`;
  let why='The exact classifiers and thresholds are shared by every agent using this blueprint. Saving a policy does not turn on an agent.';
  let remains=off?'Off is a valid saved choice. No runtime test is required.':simulation?'Simulation is non-blocking. Diagnostics are optional, and policy tips depend on provider and client support.':ready?'Explicitly choose Purview for an agent using this blueprint. Nothing has been enabled automatically.':'Enforce needs an approved clean negative and intended-classifier examples before current behavior can be verified.';
  let next=off?'Continue to agents; keeping Purview off is valid.':simulation?'Continue to agents, or inspect optional diagnostics.':ready?'Choose an agent, then review its protection choices.':'Continue to behavior tests for this exact profile.';
  let actions=link('/agents','Continue to agents',true);
  if(!off&&!ready&&isAdmin())actions=simulation?actions+link(profileRoute('runtime'),'Optional behavior diagnostics'):link(profileRoute('runtime'),'Continue to behavior tests',true);
  if(!off&&!connectionCurrent()) {
    title='Policy saved; refresh protection readiness';
    remains='The saved choice is preserved, but the connection or classifier inventory is no longer current. Earlier test results cannot restore readiness.';
    next='Read the connection, then obtain a fresh reviewed refresh where permitted.';
    actions=link('/settings/connection','Review connection readiness',true);
  }
  if(state!=='complete') {
    title={pending:'Shared policy configuration is pending',failed:'Shared policy configuration failed',unknown:'The shared policy result is not confirmed','read-error':'Shared policy status could not be checked'}[state]||'Shared policy status is unknown';
    happened=state==='failed'?'The known configuration operation failed.':state==='pending'?'The reviewed configuration was accepted; saved-profile readback is not complete.':'No reliable current result is available. The operation may already have been accepted.';
    why='Only readback of the original operation can resolve its outcome without duplicating a shared change.';
    remains='The last saved profile is not proof that this operation succeeded. No agent has been enabled.';
    next='Check the existing operation. Do not create or confirm a replacement to recover a lost result.';
    actions=button('policy-check','Check existing operation','primary')+link('/agents','Back to agents');
  }
  if(!isAdmin()) {
    next='A Gateway Administrator must review changes and approve behavior tests. You can read the saved policy or return to agents.';
    actions=link('/agents','Back to agents',true);
  }
  const scope=card('Exact shared scope',`<dl class="summary-list"><div><dt>Shared profile</dt><dd id="selected-profile">${esc(profile.id)}</dd></div><div><dt>Blueprint</dt><dd>${esc(profile.blueprint)} · ${esc(profile.blueprintId)}</dd></div><div><dt>DLP location</dt><dd>Blueprint Individual · ${sharedAgents(profile).length} fixture agents</dd></div><div><dt>Saved mode</dt><dd>${esc(modeLabel(profile.mode))}</dd></div>${selectedTypesReview(profile.types)}</dl><p class="aside-note">Any selected classifier may match (OR). The reviewed rule is UploadText / Block; simulation never enforces blocking. Know Your Data collection is optional and separate at tenant scope. Prompt Shields choices do not change.</p>${link('/settings/policy','Choose another shared policy')}`);
  const form=isAdmin()&&state==='complete'&&connectionCurrent()?`<form id="policy-form" class="card"><section class="form-section"><h2>Review the shared policy</h2><p>Changes affect every agent using ${esc(profile.blueprint)}. Review the exact mode, classifiers and thresholds before saving.</p><label for="policy-mode">Mode<select id="policy-mode">${[['Enforce','Enforce'],['SimulationWithTips','Simulation with tips'],['SimulationWithoutTips','Simulation without tips'],['Disabled','Off']].map(([value,label])=>`<option value="${value}"${app.policyDraft.mode===value?' selected':''}>${label}</option>`).join('')}</select></label><p id="mode-description" class="mode-description">${modeCopy(app.policyDraft.mode)}</p></section><section class="form-section"><h2>Sensitive information types</h2><p class="small-text">These existing profiles retain their saved selections. A new policy must choose classifiers explicitly from the current inventory.</p>${classifierEditor()}<p class="help">Changing classifiers, thresholds or mode invalidates earlier behavior proof. No choice silently enables an agent.</p></section><div class="form-actions"><a href="#/settings">Cancel</a><button type="submit" class="primary">Review protection choices</button></div></form>`:'';
  return crumbs('/settings','Shared policy')+heading('Microsoft Purview',title,`${esc(profile.blueprint)} · ${esc(profile.id)}`)+setupJourney('policy')+
    outcome('Shared policy outcome',happened,why,remains,next,actions)+
    `${form}<details class="saved-policy-library" open><summary>Saved policies and verification details (1)</summary>${scope}</details>`+
    technicalDetails(`UX-DEMO-POLICY-${profile.id}`,state==='complete'?'Completed':state,[
      ['Apply the reviewed shared configuration',state==='complete'?'Completed':state==='failed'?'Failed':'Pending','The operation remains bound to the exact profile, actor, scope and reviewed settings.'],
      ['Read back saved classifiers, thresholds and mode',state==='complete'?'Completed':'Not verified','Saved profile status is separate from operation status.'],
      ['Run approved behavior samples','Skipped','This is a separate, explicitly approved task; saving configuration did not run samples.']
    ])+protectionFixtureControls('policy',profile);
}
function protectionFixtureControls(task,profile) {
  if(!isAdmin())return '';
  const values=task==='policy'?[['complete','Saved / complete'],['pending','Pending'],['failed','Failed'],['unknown','Outcome unknown'],['read-error','Read error']]:[['draft','Approve samples'],['complete','Recorded result'],['failed','Failed'],['unknown','Outcome unknown'],['expired','Expired result'],['read-error','Read error']];
  return `<details class="fixture-tools"><summary>${task==='policy'?'Policy':'Runtime'} state fixtures (design only)</summary><p>Changes only synthetic observation state, never authorization or provider configuration.</p><label for="${task}-scenario">Synthetic ${task} outcome<select id="${task}-scenario"><option value="">Choose a fixture state</option>${values.map(([value,label])=>`<option value="${value}">${label}</option>`).join('')}</select></label><p>Profile: ${esc(profile.id)}. No real samples or tenant data are accepted.</p></details>`;
}
function agentProtectionTask() {
  if(!isAdmin())return '';
  const agent=currentAgent(), profile=profileForAgent(agent);
  return `<section class="card spacer"><div class="card-head"><h2>Choose protection for this agent</h2></div><div class="card-body"><p>Connection verification, policy saving and behavior tests never enable this agent automatically. Review ${esc(agent.name)} and its exact blueprint before changing its choices.</p><p>Shared profile: ${profile?esc(profile.id)+' · '+esc(profile.blueprint):'No matching shared profile'}. Current Purview: <strong>${esc(purviewState(agent))}</strong>.</p><div class="actions">${button('choose-agent-protection','Choose protection for this agent','primary')}${profile?link(profileRoute('policy',profile),'Review this shared policy'):link('/settings/policy','Choose a shared policy')}</div><p class="aside-note">Prompt Shields remains independent. Collection is optional; downstream telemetry delivery needs separate evidence.</p></div></section>`;
}
function modeCopy(mode){return {Enforce:'Request blocking for matching content. Enforcing is shown only after current readiness and behavior evidence support it.',SimulationWithTips:'Evaluate inline without enforcing a block. Policy tips depend on provider and client support.',SimulationWithoutTips:'Evaluate without policy tips or enforcing a block.',Disabled:'Turn policy evaluation off. This is an intentional choice.'}[mode];}
function runtime(){
  const profile=currentProfile();
  if(!profile)return crumbs('/settings','Runtime test')+setupJourney('runtime')+profilePicker('runtime');
  const selectedTypes=profile.types.filter(type=>type.selected);
  const state=app.fixture==='error'?'unknown':profile.runtime, receipt=profile.receipt;
  const off=profile.mode==='Disabled', simulation=profile.mode.startsWith('Simulation'), ready=currentBehavior(profile);
  const prefix=crumbs('/settings','Runtime test')+setupJourney('runtime');
  const context=card('Current saved profile',`<dl class="summary-list"><div><dt>Profile</dt><dd id="selected-profile">${esc(profile.id)}</dd></div><div><dt>Blueprint / effective scope</dt><dd>${esc(profile.blueprint)} · ${esc(profile.blueprintId)} · Individual</dd></div><div><dt>Current saved mode</dt><dd>${esc(modeLabel(profile.mode))}</dd></div><div><dt>Saved revision</dt><dd>${profile.revision}</dd></div>${selectedTypesReview(profile.types)}</dl><p class="aside-note">Readiness comes from the current saved profile, effective scope, inventory and unexpired behavior evidence, never a historical receipt alone.</p>${link(profileRoute('policy'),'Review this shared policy')}`);
  const reported=receipt&&['complete','expired'].includes(state);
  const details=technicalDetails(`UX-DEMO-TEST-${profile.id}`,state==='failed'?'Failed':reported?'Completed':'Not verified',[
    ['Check the clean negative control',reported?'Completed':'Not verified',reported?'The approved clean control was allowed in the recorded scope.':'No complete negative-control evidence is available for this operation.'],
    ['Check approved intended-classifier examples',reported?'Completed':'Not verified',reported?'Observed decisions belong only to the approved batch, not a claim of individual classifier attribution.':'An approved batch is still required; do not infer a passed check.'],
    ['Enable Purview for an agent','Skipped','Runtime verification never changes per-agent choices. An administrator must choose explicitly.']
  ]);
  if(off)return prefix+heading('Policy verification','This policy is off','Off is a valid saved choice, not an unfinished test.')+
    outcome('No runtime test is required',`The shared profile ${esc(profile.id)} is saved as Off.`,'Purview does not evaluate or block content under this saved mode. Prompt Shields remains independent.','No new samples are needed or permitted. Any earlier receipt remains historical.','Continue to agents; keeping Purview off is valid.',link('/agents','Continue to agents',true))+context+details;
  if(['unknown','manual','failed','read-error'].includes(state)) {
    const title={unknown:'The test result is not confirmed',manual:'This result needs administrator review',failed:'Approved behavior test failed','read-error':'Test status could not be checked'}[state];
    return prefix+heading('Runtime test',title,'Preserve the original operation and its exact profile.')+
      outcome('Recover the existing test',state==='failed'?'The known test did not verify the expected behavior.':'Complete, reliable result metadata is unavailable. Some provider work may have completed.','Resending a batch could repeat an accepted test and expose samples again.','Current enforcing behavior is not established. Private sample text is not retained for automatic replay.','Check the original test status, then resolve the reported cause. Any new test needs separately approved samples.',button('runtime-reconcile','Check test status','primary')+link(profileRoute('policy'),'Review this shared policy'))+context+details+protectionFixtureControls('runtime',profile);
  }
  if(receipt&&(state==='complete'||state==='expired')) {
    const title=ready?'Approved behavior is currently verified':simulation&&connectionCurrent()&&receipt.revision===profile.revision&&Date.now()<receipt.validUntil?'Simulation diagnostics complete':'Historical result; current verification required';
    const action=ready||title==='Simulation diagnostics complete'?link('/agents','Continue to agents',true):!connectionCurrent()?link('/settings/connection','Review connection readiness',true):button('runtime-new','Review new samples','primary');
    const results=card('Historical runtime test receipt',`<p>Recorded mode: ${esc(modeLabel(receipt.mode))}. Profile ${esc(receipt.profileId)}, revision ${receipt.revision}.</p><p>Recorded ${esc(new Date(receipt.recordedAt).toISOString())} UTC; valid no later than ${esc(new Date(receipt.validUntil).toISOString())} UTC.</p><table><caption>Simulated approved sample observations</caption><thead><tr><th>Sample</th><th>Observed behavior</th></tr></thead><tbody><tr><td>Clean negative control</td><td>${badge('Allowed','good')}</td></tr><tr><td>Intended-classifier examples</td><td>${badge(receipt.mode==='Enforce'?'Blocked':'Simulation · not blocked',receipt.mode==='Enforce'?'warn':'blue')}</td></tr></tbody></table><p class="aside-note">No raw sample content is retained in this report. Individual classifier attribution is unavailable; untested content is not certified.</p>`);
    return prefix+heading('Runtime test',title,`${esc(profile.blueprint)} · ${esc(profile.id)}`)+
      outcome('Behavior test outcome',`The approved clean control was allowed; the intended-classifier examples were ${receipt.mode==='Enforce'?'blocked':'not blocked in simulation'} in the recorded effective scope.`,
        ready?'Current saved-profile and scope checks still match this unexpired result. Each real request must still be evaluated.':'A recorded result describes its earlier scope. Only matching current evidence can establish readiness; simulation remains non-blocking.',
        ready?'Choose protection for an agent explicitly. No agent, collection setting or telemetry destination was changed.':title==='Simulation diagnostics complete'?'Simulation remains non-blocking and needs no enforcement certification. Agent choices stay explicit; collection is optional.':'Refresh any stale prerequisites and review the current profile before another approved test. Historical diagnostics never become current block proof.',
        ready||title==='Simulation diagnostics complete'?'Choose an agent using this exact blueprint, then review its protection choices.':'Do not rerun the old batch or treat its receipt as current readiness.',action)+
      `<div class="grid-two">${results}${context}</div>`+details+protectionFixtureControls('runtime',profile);
  }
  if(profile.operation!=='complete'||!connectionCurrent())return prefix+heading('Policy verification','Refresh protection readiness before testing','Your saved policy and original operation are preserved.')+
    outcome('A prerequisite needs attention','The saved profile, connection or classifier inventory is not ready for a new test.','Private samples may only be approved against current profile and effective-scope bindings.','No batch has been sent and no earlier receipt overrides this blocker.','Resolve the named prerequisite, then return to this exact profile.',profile.operation!=='complete'?link(profileRoute('policy'),'Check policy configuration',true):link('/settings/connection','Review connection readiness',true))+context;
  return prefix+heading('Policy verification','Test policy behavior',simulation?'Optional diagnostics for a non-blocking simulation policy.':'Approve a clean negative and intended-classifier examples for this saved Enforce policy.')+
    outcome('Approve a private behavior test',`The exact ${esc(profile.id)} profile is saved as ${esc(modeLabel(profile.mode))}. No samples have been sent by opening this page.`,'The clean negative checks that harmless text is allowed. Intended-SIT examples test the expected behavior in the effective shared scope.','Review every selected classifier and threshold. Samples remain private and ephemeral; only the approved batch may be sent, never replayed automatically.',
      simulation?'Diagnostics are optional. Continue to agents or explicitly approve a diagnostic batch below.':'Approve the clean negative and an intended example for each selected classifier below, then confirm this one batch.',
      simulation?link('/agents','Continue to agents',true):'')+
    `<div class="grid-two"><form id="runtime-form" class="card"><section class="form-section"><h2>Review the sample set</h2><p class="small-text">Design fixture: these fixed fictional examples never leave this page. The live workflow sends only explicitly approved samples through its private HTTPS path. Collection is not required.</p>
    <div class="sample-card"><label class="check-line"><input type="checkbox" id="sample-negative" required><span>Clean negative control<small>Expected to be allowed. No intended sensitive information.</small></span></label><span class="sample-content">Please summarize tomorrow’s public agenda.</span></div>
    ${selectedTypes.map((type,index)=>`<div class="sample-card"><label class="check-line"><input type="checkbox" id="sample-positive-${index}" required><span>Intended example: ${esc(type.name)}<small>${esc(type.id)} · ${profile.mode==='Enforce'?'Expected to be blocked':'Simulation only; no enforced block'}</small></span></label><span class="sample-content">${type.id==='synthetic-sit-employee'?'Fictional employee reference: DEMO-EMPLOYEE-0000':'Fictional project reference: DEMO-PROJECT-0000'}</span></div>`).join('')}
    <label class="check-line"><input id="sample-consent" type="checkbox" required><span>I reviewed these synthetic samples and approve this one test.</span></label></section><div class="form-actions"><a href="#${profileRoute('policy')}">Back to this policy</a><button type="submit" class="primary">Review test</button></div></form>${context}</div>`+protectionFixtureControls('runtime',profile);
}
function companionInput(){
  return `<h3>Finish on Windows, then paste the result</h3><ol class="companion-instructions">
    <li><strong>Download, then open its folder.</strong> On the live Gateway, use the browser's Show in folder action. Do not double-click the script. This prototype does not download anything.</li>
    <li><strong>Open PowerShell 7 in that folder.</strong> In File Explorer, right-click empty space and choose Open in Terminal. Use pwsh -NoLogo -NoProfile if needed; if PowerShell 7 is missing, use your organization's approved installation process. Check the folder and filename if PowerShell cannot find the download.</li>
    <li><strong>Trust this one download before running it.</strong> Review the file and follow your organization's policy before using the live page's copyable Unblock-File command. No output is normal. It removes only the file's download marker, not execution policy. A blocked script cannot unblock itself. If signed scripts are required, request an approved signed copy; never lower or bypass policy.</li>
    <li><strong>Run the full connection command.</strong> Use the live task's current command before its UTC expiry; never edit the IDs or deadline.</li>
    <li><strong>Sign in and wait for the result.</strong> Official Microsoft sign-in happens outside this prototype. The companion prints one A365GW_CONNECTION_RESULT: line.</li>
    <li><strong>Copy that result and paste it below. No file is needed.</strong> On the live Gateway, copy the entire line including its prefix, without commands or sign-in messages. Review and submit once for independent Gateway verification.</li>
  </ol><p id="prototype-companion-help" class="small-text">Design fixture only: use the synthetic result button below. Never paste real tenant output, passwords or sign-in tokens here.</p>
  <label for="prototype-companion-output">Paste companion result</label>
  <textarea id="prototype-companion-output" rows="5" maxlength="128" autocomplete="off" spellcheck="false" aria-invalid="false" aria-describedby="prototype-companion-help prototype-companion-status" placeholder="A365GW_CONNECTION_RESULT:..."></textarea>
  <p id="prototype-companion-status" class="small-text" role="status">No text file is required.</p>
  <div class="actions">${button('use-synthetic-companion','Use synthetic result')}</div>
  <details class="spacer"><summary>Or upload a saved result (optional)</summary><p class="small-text">The live Gateway accepts a saved text file containing the same single result line and applies the same checks. This prototype never reads files; use the synthetic result above.</p></details>
  <div class="actions spacer">${button('companion-review','Review companion connection','primary','disabled')}</div>`;
}
function connection(){
  const current=app.fixture==='error'?'read-error':observedConnectionState();
  const pending=current==='pending', completed=current==='connected', expired=current==='expired';
  const titles={connected:'Purview connection verified',pending:'Checking the Purview connection',expired:'Connection verified earlier; refresh required',waiting:'Connect the tenant and load its inventory',failed:'Connection verification failed',unknown:'The connection result is not confirmed','read-error':'Connection status could not be checked','launch-expired':'Connection launch expired','wrong-actor':'This connection belongs to another administrator',unavailable:'Purview setup is unavailable'};
  let happened=completed?'The Gateway independently verified its own configured app access and loaded a current classifier inventory.':pending?'Companion result received. Checking Gateway access.':expired?'The original connection completed successfully. Its connection or inventory readiness has now expired.':current==='waiting'?'The original connection is waiting for the expected administrator’s Windows result.':current==='failed'?'Connection verification failed. The Windows sign-in result did not establish Gateway app access.':current==='launch-expired'?'The accepted Windows launch expired without a current completion.':current==='wrong-actor'?'This waiting task is bound to Jordan Davis, not the current fixture account.':current==='unavailable'?'A required Purview capability is not available in this Gateway.':'A reliable current status could not be read. The original operation may already have been accepted.';
  const why='Administrator sign-in does not transfer access to the Gateway. The independent app-access check and classifier definitions are prerequisites for reviewing an exact shared policy.';
  let remains=completed?'No shared DLP policy was created, no agent was enabled, and DLP blocking has not been tested. Collection is optional and separate.':expired?'Historical completion is preserved, but it is not current readiness. Old evidence and commands must not be replayed.':pending?'Wait for independent verification and the current classifier inventory. DLP protection is not enabled by this step.':'The connection is not currently verified. DLP protection is not enabled by this step.';
  let next=completed?'Choose a blueprint shared by agents, then review its exact classifiers, thresholds, mode and shared impact.':expired?'Review a fresh connection authorization, then complete only the new task. Never rerun old evidence.':pending?(app.observation.stopped?'Automatic updates stopped. Resume automatic updates to read the same operation; it may still be running. No result will be submitted again.':'Keep this page open for bounded read-only updates, or stop automatic updates without cancelling the original work. Do not resubmit its result.'):current==='waiting'?'Follow the six Windows steps below as the expected administrator, then review and submit the synthetic example once.':current==='failed'?'Check the original operation and share its failure reference with your administrator. Resolve that cause before a separately reviewed attempt.':current==='launch-expired'?'Review a fresh authorization; do not edit or run the expired command.':current==='wrong-actor'?'Ask Jordan Davis to reopen the original task, or return to Settings. Do not create a replacement under another account.':current==='unavailable'?'Ask an installation administrator about the missing capability. Agents with Purview off can continue normally.':'Check the original operation by GET. Do not create, confirm or submit another connection to recover this result.';
  const observationAction=pending?(app.observation.stopped?button('connection-resume','Resume automatic updates','primary'):button('connection-stop','Stop automatic updates')):'';
  let actions=completed?link('/settings/policy','Continue to shared policies',true):expired||current==='launch-expired'?button('review-connection-refresh','Review connection refresh','primary'):pending?observationAction+button('connection-check','Check connection status'):['failed','unknown','read-error'].includes(current)?button('connection-check','Check connection status','primary'):current==='unavailable'?link('/agents','Back to agents',true):'';
  if(!isAdmin()) {
    next='A Gateway Administrator completes the Windows handoff, reviews shared policies and approves tests. You can read this operation without changing it.';
    actions=observationAction+button('connection-check','Check connection status')+link('/agents','Back to agents');
  }
  const status=pending?`<p id="connection-observation" class="observation-status" data-read-count="${app.observation.reads}" data-operation="${esc(app.connectionId)}">${observationText()}</p>`:'';
  const context=card('Connection context',`<dl class="summary-list"><div><dt>Tenant</dt><dd>Contoso · synthetic tenant</dd></div><div><dt>Expected administrator</dt><dd>Jordan Davis · synthetic administrator</dd></div><div><dt>Original connection operation</dt><dd id="connection-reference">${esc(app.connectionId)}</dd></div><div><dt>Inventory generation</dt><dd>${esc(app.inventoryGeneration)}</dd></div><div><dt>Inventory</dt><dd>${badge(completed?'Current':'Not current',completed?'good':'')}</dd></div>${completed||expired?`<div><dt>Historically verified at (UTC)</dt><dd>${esc(new Date(app.connectionVerifiedAt).toISOString())}</dd></div><div><dt>Readiness expires at (UTC)</dt><dd>${esc(new Date(app.connectionValidUntil).toISOString())}</dd></div>`:''}${current==='waiting'||current==='launch-expired'?`<div><dt>Windows launch expires at (UTC)</dt><dd>${esc(new Date(app.launchExpiresAt).toISOString())}</dd></div>`:''}</dl>${app.previousConnectionId?`<p class="aside-note">Earlier operation retained: ${esc(app.previousConnectionId)}. Its old evidence is not reused.</p>`:''}<p class="aside-note">The separate completion approval continues this original operation. The helper reads definitions, not prompts or documents, creates no policy, and transfers no administrator sign-in session.</p>${button('connection-reopen','View connection status')}`);
  const steps=[
    ['Validate the reviewed administrator handoff',current==='waiting'||current==='launch-expired'?'Waiting':['connected','expired','pending','failed'].includes(current)?'Completed':'Not verified','Tenant, administrator, original operation, inventory generation and expiry must match.'],
    ['Verify Gateway app access and load classifier definitions',completed||expired?'Completed':current==='failed'?'Failed':pending?'Running':'Not verified',completed||expired?'Independent app-access verification completed; readiness can still expire.':current==='failed'?'Failure reference: SYNTHETIC_CONNECTION_UNVERIFIED. Fix the cause before a separately reviewed attempt.':'Do not infer Gateway access from a successful administrator sign-in.'],
    ['Create or update a shared DLP policy','Skipped','A connection operation does not create or modify a blueprint policy.'],
    ['Run approved runtime behavior tests','Skipped','No sample test was run and DLP blocking has not been proven.'],
    ['Record the connection outcome',completed||expired?'Completed':current==='failed'?'Failed':'Not verified','Historical completion and current readiness are separate facts.']
  ];
  const inventorySummary=isAdmin()&&(completed||expired)?card('Existing sensitive information types',`<p>${new Set(app.profiles.flatMap(profile=>profile.types.map(type=>type.id))).size} existing sensitive information types were found in this synthetic tenant.</p><p>A sensitive information type (SIT) recognizes a kind of data. Choose types once in Set shared policy, not here.</p><p>${completed?'This synthetic inventory is current.':'This inventory is expired; review a fresh connection before using it.'} Reading saved status does not renew its expiry.</p>`):'';
  const activeObservation=pending&&!app.observation.stopped;
  return crumbs('/settings','Tenant connection')+heading('Microsoft Purview',titles[current]||'Connection status is unknown','Understand the result before taking the next protection step.',activeObservation?'<span class="activity-cue"><span class="spinner" aria-hidden="true"></span>Reading saved status</span>':'')+setupJourney('connection')+
    outcome('Connection outcome',happened,why,remains,next,actions,pending&&!app.observation.stopped)+status+inventorySummary+
    `<div class="${current==='waiting'&&isAdmin()?'grid-two':'stack'}">${current==='waiting'&&isAdmin()?card('Finish the Windows handoff',companionInput()):''}${context}</div>`+
    technicalDetails(app.connectionId,completed||expired?'Completed':current==='failed'?'Failed':pending?'Pending':'Not verified',steps)+
    (isAdmin()?`<details class="fixture-tools"><summary>Connection state fixtures (design only)</summary><p>These controls change only local synthetic readback. Pending results appear at the next three-second status check; a terminal result also reloads current connection/inventory context. No provider is contacted.</p><label for="connection-scenario">Synthetic connection outcome<select id="connection-scenario"><option value="">Choose a fixture state</option>${[['connected','Verified'],['waiting','Waiting for Windows input'],['pending','Pending verification'],['stopped','Five-minute updates stopped'],['failed','Failed verification'],['unknown','Outcome unknown'],['read-error','Read error'],['expired','Completed, readiness expired'],['launch-expired','Windows launch expired'],['wrong-actor','Different administrator'],['unavailable','Prerequisite unavailable']].map(([value,label])=>`<option value="${value}">${label}</option>`).join('')}</select></label>${pending?`<div class="actions">${button('connection-verified','Simulate verified connection')}${button('connection-context-expired','Simulate completed connection with expired readiness')}${button('connection-failed','Simulate failed verification')}</div>`:''}</details>`:'');
}
function defaults(){
  return crumbs('/settings','Registration defaults')+
    heading('Settings','Registration defaults','Defaults guide new registrations. Each agent’s saved choices remain separate.')+
    card('Telemetry destinations',`<label class="check-line"><input id="default-agent365" type="checkbox" ${app.defaults.agent365?'checked':''}><span>Agent 365 observability on for new agents</span></label><label class="check-line"><input id="default-monitor" type="checkbox" ${app.defaults.monitor?'checked':''}><span>Azure Monitor mirror on for new agents</span></label><p class="small-text">Protection choices are reviewed per agent. Changing a default does not rewrite existing registrations.</p>${button('save-defaults','Save defaults','primary')}`);
}
function integration(){return heading('External developer guide','Connect your external agent','Use the Gateway endpoint and external agent ID provided by your administrator. Load the key from a secret manager.')+notice('Gateway credentials are for this registration','The external agent does not receive Microsoft Entra tokens or managed-identity identifiers.')+`<div class="grid-two">${card('Before your first interaction',`<ol class="steps"><li><span class="step-marker">1</span><div><h3>Check registration readiness</h3><p>Wait until your administrator completes the Agent 365 setup.</p></div></li><li><span class="step-marker">2</span><div><h3>Evaluate every prompt</h3><p>Always evaluate the prompt and obtain a valid allow receipt before generating, regardless of remembered feature settings.</p></div></li><li><span class="step-marker">3</span><div><h3>Call your model once</h3><p>A denial or proof already known to be invalid or expired must stop generation. Keep evaluation and generation close together.</p></div></li><li><span class="step-marker">4</span><div><h3>Submit the interaction</h3><p>Send the matching prompt, result, interaction ID, and receipt to the Gateway.</p></div></li></ol><pre id="integration-sample">${esc(sampleCommand(currentAgent().externalId))}</pre>${button('copy','Copy sample command','','data-copy="integration-sample"')}`)}${card('Understand the outcome',`<h3>Accepted by Gateway</h3><p class="small-text">The Gateway accepted the submission for processing.</p><h3>Delivered downstream</h3><p class="small-text">Delivery to Agent 365 or Azure Monitor requires separate evidence. An export attempt is not delivery confirmation.</p><h3>Need another key?</h3><p class="small-text no-margin">Ask your Gateway Administrator for a replacement through your secret manager. External developers do not need an Admin UI role.</p>`)}</div>`;}
function installation(){
  if(app.fixture==='error')return heading('Gateway installer','Deployment stopped at a safe checkpoint','Completed steps are preserved. Review the failure before resuming.')+notice('Choose the next action from this checkpoint','The configured service capacity is unavailable. Review the exact stopped step and diagnostic reference. Do not rerun the whole installation.','error',button('review-resume','Review resume','primary'))+card('Deployment progress','<p>Completed: foundation and application identities.</p><p>Stopped: service capacity validation.</p><p class="small-text">Reference: UX-DEMO-INSTALL-001. Changing reviewed inputs requires a fresh plan.</p>');
  if(app.installer==='verified')return heading('Gateway installer','Your Gateway is installed','Deployment verification is complete. Open the Admin UI to register your first external agent.')+notice('Installation verified','The Gateway resources, identities, endpoints, and health checks have been verified. An Active agent and policy behavior are separate next steps.','success')+card('Continue in the Admin UI',`${copyField('admin-url','Admin UI URL','https://admin.gateway.example.invalid')}<p class="small-text">Sign in with your Gateway Administrator account, then open Getting started.</p>${link('/setup','Open getting started',true)}`);
  if(app.installer==='deploying')return heading('Gateway installer','Your Gateway is being prepared','Keep this progress page open, or return to the preserved checkpoint later.')+card('Deployment progress',`<ol class="steps"><li class="done"><span class="step-marker">✓</span><div><h3>Prepare shared resources and identities</h3><p>Completed.</p></div></li><li class="current"><span class="step-marker">2</span><div><h3>Deploy and verify the Gateway</h3><p>Verifying exact resources, health, and permissions.</p></div></li><li><span class="step-marker">3</span><div><h3>Open the Admin UI</h3><p>Available after verification completes.</p></div></li></ol><div class="actions spacer">${button('installer-status','Refresh deployment status','primary')}</div>`);
  return heading('Gateway installer','Review your installation plan','Check the tenant, subscription, capabilities, and cost choices before deployment.')+notice('Separate from agent onboarding','This installer prepares the shared Gateway. Agent registration and protection policy configuration happen later in the hosted Admin UI.')+`<div class="grid-two">${card('Deployment destination',`<dl class="summary-list"><div><dt>Tenant</dt><dd>Contoso · synthetic tenant</dd></div><div><dt>Subscription</dt><dd>Contoso development lab · synthetic subscription</dd></div><div><dt>Region</dt><dd>Korea Central</dd></div><div><dt>Environment</dt><dd>Development</dd></div></dl><div class="divider-line"></div><h3>Capabilities</h3><label class="check-line"><input type="checkbox" checked disabled><span>Shared Prompt Shields service</span></label><label class="check-line"><input id="install-purview" type="checkbox" checked><span>Prepare Microsoft Purview prerequisites</span></label><p class="help">Preparation does not connect tenant policy authority or choose classifiers.</p><label class="check-line"><input id="install-review" type="checkbox"><span>I reviewed the destination, preview dependency, permissions, and cost choices.</span></label>${button('review-installation','Review and deploy','primary')}`)}${card('What the plan includes',`<p class="small-text">Azure hosting, private data services, application identities, and the Gateway control plane.</p><p class="small-text">Content Safety quota and any paid hosting are explicit choices. Purview prerequisites do not prove license eligibility or protection readiness.</p><details><summary>Review technical deployment details</summary><p>The accepted source, configuration, and provider plan are bound together. A changed input requires renewed review. Interrupted setup resumes from verified checkpoints.</p></details>`)}</div>`;
}
function reviewRegistrationPolicy(){
  const isNew=app.draft.blueprint==='new';
  const scope=isNew?'These choices bind only to this new registration and its new blueprint after the exact identity is known.':`This blueprint is currently used by ${sharedAgents().length} agents. Changes affect every agent using it.`;
  const profile=registrationProfile();
  openDialog(isNew?'Review the new blueprint policy':'Review shared policy impact',`<p>${scope}</p><dl class="summary-list"><div><dt>Mode</dt><dd>${esc(modeLabel(profile.mode))}</dd></div>${selectedTypesReview(profile.types)}</dl><label class="check-line"><input id="policy-impact" type="checkbox"><span>I reviewed the policy scope and affected agents.</span></label>`,'Confirm policy review',()=>{
    if(!$('#policy-impact').checked){announce('Review and acknowledge the policy scope before continuing.');$('#policy-impact').focus();return;}
    app.policyReviewed=true;closeDialog();render(true);toast('Policy review confirmed for these registration choices.');
  });
}
function reviewRegistration(){
  if(app.draft.purview&&!app.policyReviewed){reviewRegistrationPolicy();return;}
  const d=app.draft;
  openDialog('Review registration',`<dl class="summary-list"><div><dt>Agent</dt><dd>${esc(d.name)}</dd></div><div><dt>External agent ID</dt><dd>${esc(d.externalId)}</dd></div><div><dt>Blueprint</dt><dd>${d.blueprint==='new'?'New: '+esc(d.blueprintName):'Reuse Contoso assistants'}</dd></div><div><dt>Prompt Shields</dt><dd>${d.shield?'On':'Off'}</dd></div><div><dt>Microsoft Purview</dt><dd>${d.purview?'Reviewed '+modeLabel(registrationProfile().mode)+' policy':'Off'}</dd></div></dl><p class="aside-note">After registration is accepted, save the one-time key before continuing to Agent 365 setup.</p>`,'Register and show key',()=>{app.newAgent={id:'agent-new',name:d.name,externalId:d.externalId,status:'Provisioning',blueprint:d.blueprint==='new'?d.blueprintName:'Contoso assistants',shield:d.shield,purview:d.purview?'Configuration pending':'Off'};app.selectedAgent='agent-new';app.savedKey=false;app.handoff=true;keyState().lost=false;app.handoffReturn='/operations/current';keyState().usable=1;app.operation='waiting';app.fixture='success';closeDialog();navigate('/handoff');announce('Registration accepted. Save the one-time key now.');});
}
document.addEventListener('submit',event=>{
  event.preventDefault();const form=event.target;if(!form.reportValidity())return;
  if(form.id==='agent-search'){const data=new FormData(form);app.query=String(data.get('query')).trim();app.filter=String(data.get('status'));app.page=0;render();$('#agent-query').focus();announce('Agent search updated.');}
  if(form.id==='register-form')reviewRegistration();
  if(form.id==='policy-form'){
    const profile=currentProfile(), draft=structuredClone(app.policyDraft), revision=profile?.revision;
    if(!isAdmin()||!profile||profile.operation!=='complete'||!connectionCurrent())return;
    if(!draft.types.some(t=>t.selected)){toast('Choose at least one sensitive information type.');$('#sit-0').focus();return;}
    if(draft.types.some(t=>t.selected&&((t.maxCount!==-1&&t.minCount>t.maxCount)||t.minConfidence>t.maxConfidence))){toast('Each minimum must be no greater than its maximum.');$('#sit-0-minCount').focus();return;}
    openDialog('Review shared Purview configuration',`<p>This changes ${esc(profile.blueprint)} for every agent using that blueprint (${sharedAgents(profile).length} fixture agents). It does not enable any agent.</p><dl class="summary-list"><div><dt>Exact profile</dt><dd>${esc(profile.id)} · revision ${revision}</dd></div><div><dt>Blueprint application / DLP location</dt><dd>${esc(profile.blueprintId)} · Individual</dd></div><div><dt>Requested mode</dt><dd>${esc(modeLabel(draft.mode))}</dd></div>${selectedTypesReview(draft.types)}</dl><p class="aside-note">Any selected classifier may match (OR). Rule: UploadText / Block. Earlier behavior verification becomes invalid. Saved configuration still needs independent readback and any required runtime proof. Collection remains optional and separate.</p><label class="check-line"><input id="confirm-shared" type="checkbox"><span>I understand this policy is shared by every agent using this blueprint.</span></label>`,'Confirm and queue shared policy',()=>{
      if(!$('#confirm-shared').checked){announce('Acknowledge the shared policy impact.');$('#confirm-shared').focus();return;}
      if(!isAdmin()||currentProfile()!==profile||profile.revision!==revision||profile.operation!=='complete'||!connectionCurrent()||JSON.stringify(draft)!==JSON.stringify(app.policyDraft)){closeDialog();render(true);toast('The review changed or expired. Review the current profile again.');return;}
      profile.pending=draft;profile.operation='pending';app.policyWrites++;
      closeDialog();render(true);toast('Configuration accepted. Check the existing operation for saved-profile readback.');
    });
  }
  if(form.id==='runtime-form'){
    const profile=currentProfile(), revision=profile?.revision;
    if(!isAdmin()||!profile||profile.mode==='Disabled'||profile.operation!=='complete'||!connectionCurrent())return;
    openDialog('Review protection test',`<p>Approve one clean negative control and ${profile.types.filter(t=>t.selected).length} fictional intended-classifier example(s) for ${esc(profile.blueprint)}. This fixture sends nothing outside the page.</p><dl class="summary-list"><div><dt>Exact saved profile / revision</dt><dd>${esc(profile.id)} · ${revision}</dd></div><div><dt>Mode</dt><dd>${esc(modeLabel(profile.mode))}</dd></div><div><dt>Execution identity</dt><dd>Synthetic test registration for ${esc(profile.blueprint)}</dd></div><div><dt>Effective scope</dt><dd>${esc(profile.blueprintId)} · Blueprint Individual</dd></div>${selectedTypesReview(profile.types)}</dl><p class="aside-note">Samples remain private and ephemeral. This confirmation is single-use; a changed profile, scope or expired review requires new consent. An uncertain result is recovered by GET, never sample replay. Individual classifier attribution is unavailable.</p>`,'Confirm and send approved batch',()=>{
      if(!isAdmin()||currentProfile()!==profile||profile.revision!==revision||profile.operation!=='complete'||profile.mode==='Disabled'||!connectionCurrent()){closeDialog();render(true);toast('Current profile context changed. No samples were sent.');return;}
      profile.receipt={profileId:profile.id,revision,mode:profile.mode,scope:profile.blueprintId,inventoryGeneration:app.inventoryGeneration,verified:profile.mode==='Enforce',recordedAt:Date.now(),validUntil:Math.min(Date.now()+10*60*1000,app.connectionValidUntil)};
      profile.runtime='complete';app.sampleSubmissions++;closeDialog();render(true);announce('Simulated approved sample results are available. No agent was enabled.');
    });
  }
});
document.addEventListener('input',event=>{
  const e=event.target;
  if(e.id==='prototype-companion-output'){
    const valid=e.value.trim()===syntheticCompanionResult;
    $('[data-action="companion-review"]').disabled=!valid;
    e.setAttribute('aria-invalid',String(Boolean(e.value.trim())&&!valid));
    $('#prototype-companion-status').textContent=valid?'Synthetic result ready for review. This is not a real connection.':e.value.trim()?'Use only the synthetic design result; do not paste real tenant data.':'No text file is required.';
  }
  if(e.closest('#register-form')&&['name','externalId','blueprintName'].includes(e.name)){app.draft[e.name]=e.value;app.policyReviewed=false;}
  if(e.id==='policy-classifier-search'){
    app.classifierQuery=e.value;const query=e.value.trim().toLowerCase();
    const choices=[...document.querySelectorAll('.classifier-choice')];
    for(const choice of choices)choice.hidden=!choice.dataset.classifier.includes(query);
    $('#classifier-search-count').textContent=`${choices.filter(choice=>!choice.hidden).length} of ${choices.length} available types shown.`;
  }
  if(e.dataset.typeIndex!==undefined)app.policyDraft.types[Number(e.dataset.typeIndex)][e.dataset.typeField]=e.type==='checkbox'?e.checked:e.dataset.typeField==='maxCount'&&e.value.toLowerCase()==='any'?-1:Number(e.value);
});
document.addEventListener('change',event=>{
  const e=event.target;
  if(e.id==='fixture-role'){if(app.handoff&&!app.savedKey)keyState().lost=true;app.role=e.value;app.handoff=false;app.savedKey=false;render(true);return;}
  if(e.id==='fixture-state'){app.fixture=e.value;if(e.value==='error')app.operation='waiting';render(true);return;}
  if(e.id==='saved-key'){app.savedKey=e.checked;$('[data-action="continue-setup"]').disabled=!e.checked;return;}
  if(e.id==='profile-select'){navigate(`/settings/${e.dataset.task}${e.value?'?profile='+encodeURIComponent(e.value):''}`);return;}
  if(e.id==='policy-mode'){app.policyDraft.mode=e.value;$('#mode-description').textContent=modeCopy(e.value);return;}
  if(e.dataset.typeField==='selected'){
    app.policyDraft.types[Number(e.dataset.typeIndex)].selected=e.checked;
    const id=e.id;render();$('#'+id)?.focus();return;
  }
  if(e.id==='connection-scenario'){chooseConnectionFixture(e.value);return;}
  if(e.id==='policy-scenario'){if(e.value){currentProfile().operation=e.value;app.fixture='success';render(true);}return;}
  if(e.id==='runtime-scenario'){
    const profile=currentProfile();
    if(!e.value)return;
    if(['complete','expired'].includes(e.value)&&!profile.receipt){toast('No historical result exists. Approve a synthetic batch first.');return;}
    if(e.value==='expired')profile.receipt.validUntil=Date.now();
    profile.runtime=e.value;app.fixture='success';render(true);return;
  }
  if(e.closest('#register-form')&&['blueprint','shield','purview','agent365','azureMonitor'].includes(e.name)){
    app.draft[e.name]=e.type==='checkbox'?e.checked:e.value;app.policyReviewed=false;render();const target=$(`[name="${e.name}"]${e.type==='radio'?`[value="${e.value}"]`:''}`);target?.focus();
  }
});
document.addEventListener('click',async event=>{
  if(event.target.closest('.skip-link')){event.preventDefault();$('#main').focus();return;}
  const anchor=event.target.closest('a[href^="#/"]');
  if(anchor){event.preventDefault();go(anchor.getAttribute('href').slice(1),anchor.dataset.agent);return;}
  const target=event.target.closest('[data-action]');if(!target||target.disabled)return;
  const action=target.dataset.action;
  if(action==='dialog-close'){closeDialog();return;}
  if(action==='dialog-confirm'){dialogAction?.();return;}
  if(action==='copy'){
    const source=$('#'+target.dataset.copy), value=source?.value??source?.textContent??'';
    try{await navigator.clipboard.writeText(value);const before=target.textContent;target.textContent='Copied';toast('Copied to clipboard.');setTimeout(()=>{if(target.isConnected)target.textContent=before;},2300);}catch{if(source?.select)source.select();toast('Copy is unavailable. Select the text and copy it manually.');}return;
  }
  if(action==='retry'){app.fixture='success';render(true);toast('Latest information loaded.');}
  if(action==='clear-search'){app.query='';app.filter='';app.page=0;render();$('#agent-query')?.focus();announce('Search filters cleared.');}
  if(action==='next-page'||action==='prev-page'){app.page+=action==='next-page'?1:-1;render();announce(`Page ${app.page+1} loaded.`);$('#main h1')?.focus();}
  if(action==='new-blueprint'){app.draft.blueprint='new';render();$('#blueprint-name').focus();}
  if(action==='review-registration-policy')reviewRegistrationPolicy();
  if(action==='continue-setup'){if(!app.savedKey)return;app.handoff=false;navigate(app.handoffReturn);}
  if(action==='complete-registry')openDialog('Complete Agent 365 registration?',`<p>Use your administrator session to complete this agent’s Registry step.</p><dl class="summary-list"><div><dt>External agent ID</dt><dd>${esc(currentAgent().externalId)}</dd></div><div><dt>Identity mapping</dt><dd>Existing blueprint and child identity are retained.</dd></div></dl><p class="aside-note">A Microsoft sign-in or consent prompt may be required. If the result is uncertain, the Gateway checks the existing registration before any further action.</p>`,'Complete registration',()=>{app.operation='active';currentAgent().status='Active';closeDialog();render(true);toast('Agent setup complete. Registration is Active.');});
  if(action==='reconcile-registry'){app.operation='active';currentAgent().status='Active';render(true);toast('Existing registration found. No new registration was sent.');}
  if(action==='refresh-operation'){render();toast('Status refreshed. Completed steps were not repeated.');}
  if(action==='toggle-agent'){
    const a=currentAgent();if(!['Active','Disabled'].includes(a.status))return;
    const enable=a.status==='Disabled';
    openDialog(`${enable?'Enable':'Disable'} this agent?`,`<p>${enable?'Enable Gateway access for this registration. Existing protection requirements still apply.':'Stop this registration from using the Gateway. Its identity mapping and audit history remain.'}</p>`,enable?'Enable agent':'Disable agent',()=>{a.status=enable?'Active':'Disabled';app.disabled.delete(a.id);closeDialog();render(true);toast('Gateway access updated.');});
  }
  if(action==='replace-key')openDialog('Issue a replacement key?','<p>Store the new key, update the external agent, and then revoke the old key. The new key will be shown once.</p>','Issue replacement',()=>{keyState().usable++;keyState().issued++;app.savedKey=false;app.handoff=true;app.handoffReturn='/agents/detail';keyState().lost=false;closeDialog();navigate('/handoff');});
  if(action==='revoke-key'){
    if(keyState().usable<=1){openDialog('Keep one usable Gateway key','<p>This is the last usable key. Issue a replacement and update the external agent before revoking this key.</p>','Done',closeDialog,{cancel:'Close'});return;}
    openDialog('Revoke the old Gateway key?','<p>Requests using the old key will stop being accepted. Your replacement remains usable.</p><label class="check-line"><input id="key-updated" type="checkbox"><span>I updated the external agent to use the replacement.</span></label>','Revoke old key',()=>{if(!$('#key-updated').checked){announce('Confirm the external agent uses its replacement key.');$('#key-updated').focus();return;}keyState().usable--;keyState().lost=false;closeDialog();render(true);toast('Old key revoked. The replacement key remains usable.');},{danger:true});
  }
  if(action==='delete-agent')openDialog('Delete this Gateway registration?','<p>This removes the registration and its Gateway access. Microsoft Entra identities, Agent 365 registrations, and shared Purview policies remain.</p>','Delete Gateway registration',()=>{app.deleted.add(currentAgent().id);if(app.selectedAgent==='agent-new')app.newAgent=null;closeDialog();navigate('/agents');toast('Gateway registration deleted. Microsoft resources were not deleted.');},{danger:true});
  if(action==='view-audit')openDialog('Agent audit history','<p>Recent Gateway events for this registration.</p><ul class="link-list"><li>Registration accepted · Gateway Administrator</li><li>Gateway key issued · Gateway Administrator</li><li>Blueprint identity verified · Gateway workflow</li></ul>','Done',closeDialog,{cancel:'Close'});
  if(action==='policy-summary'){
    const profile=registrationProfile();
    openDialog('Shared policy summary',`<p>${esc(profile.blueprint)} · ${esc(profile.id)} · ${sharedAgents(profile).length} agents.</p><p>Saved mode: ${esc(modeLabel(profile.mode))}. Configuration saved; enforcing behavior is not claimed.</p><dl class="summary-list">${selectedTypesReview(profile.types)}</dl><p>Only a Gateway Administrator can edit policies or view runtime-test results.</p>`,'Done',closeDialog,{cancel:'Close'});
  }
  if(action==='policy-check'){
    const profile=currentProfile();if(!profile)return;
    app.fixture='success';
    if(profile.operation==='pending'&&profile.pending){
      profile.mode=profile.pending.mode;profile.types=structuredClone(profile.pending.types);profile.revision++;
      profile.operation='complete';profile.pending=null;profile.runtime='draft';
      app.policyDraft={mode:profile.mode,types:structuredClone(profile.types)};
    }
    render(true);toast('Original policy operation checked. No replacement configuration was submitted.');
  }
  if(action==='runtime-reconcile'){const profile=currentProfile();if(!profile)return;app.fixture='success';profile.runtime=profile.receipt?'complete':'manual';render(true);}
  if(action==='runtime-new'){const profile=currentProfile();if(!profile||!isAdmin())return;profile.runtime='draft';render(true);}
  if(action==='choose-agent-protection'){
    if(!isAdmin())return;
    const agent=currentAgent(), profile=profileForAgent(agent), revision=profile?.revision;
    const available=profile&&profile.operation==='complete'&&profile.mode!=='Disabled'&&connectionCurrent()&&(profile.mode!=='Enforce'||currentBehavior(profile));
    openDialog('Review this agent’s protection choices',`<p>Only ${esc(agent.name)} (${esc(agent.externalId)}) is changed by this action. No sibling or shared policy is changed.</p><p>Blueprint: ${esc(agent.blueprint)}. Profile: ${profile?esc(profile.id)+' · '+esc(modeLabel(profile.mode)):'No matching shared profile'}.</p><label class="check-line"><input id="agent-shield-choice" type="checkbox"${agent.shield?' checked':''}><span>Use Prompt Shields for this agent</span></label><label class="check-line"><input id="agent-purview-choice" type="checkbox"${agent.purview!=='Off'?' checked':''}><span>Use the shared Purview policy for this agent</span></label><p>${available?'Current prerequisites permit this choice. Keeping either protection off is valid.':'Purview cannot be enabled with the current profile or prerequisites. You may select Off, or return to review the missing readiness. The requested choice is never silently changed.'}</p><p class="aside-note">Collection is optional and separate. Test or connection completion alone never enables an agent.</p>`,'Save this agent’s choices',()=>{
      if(!isAdmin()||currentAgent()!==agent){closeDialog();return;}
      const requested=$('#agent-purview-choice').checked;
      if(requested&&(!profile||profile.revision!==revision||profile.operation!=='complete'||profile.mode==='Disabled'||!connectionCurrent()||(profile.mode==='Enforce'&&!currentBehavior(profile)))){announce('Purview prerequisites are unavailable. Select Off explicitly or review current readiness.');$('#agent-purview-choice').focus();return;}
      agent.shield=$('#agent-shield-choice').checked;agent.purview=requested?'On':'Off';app.agentFeatureWrites++;
      closeDialog();render(true);toast('Only this agent’s protection choices were saved.');
    });
  }
  if(action==='connection-reopen'){
    const current=observedConnectionState();
    const text={pending:'Companion result received. Checking Gateway access.',failed:'Connection verification failed.',connected:'Purview connection verified. Classifier inventory is current.',expired:'Connection verified earlier; refresh required. Historical completion is preserved.',waiting:'Waiting for administrator completion.',unknown:'The connection result is not confirmed.','read-error':'Current status could not be checked.'}[current]||'Current verification is not established.';
    openDialog('Connection operation',`<p>Tenant: Contoso. ${text}</p><p>Original operation: ${esc(app.connectionId)}.</p><p>Dismiss this view to leave the original operation unchanged. No result is submitted again.</p>`,'Done',closeDialog,{cancel:'Close'});
  }
  if(action==='connection-check'){app.fixture='success';readSyntheticConnection();render();}
  if(action==='connection-stop'){
    if(!canOperate()||app.connection!=='pending')return;
    app.observation.stopped=true;app.observation.stopReason='user';stopConnectionObservation();render();
    $('[data-action="connection-resume"]')?.focus();
    announce('You stopped automatic updates. The original operation may still be running. No work was cancelled.');
  }
  if(action==='connection-resume'){
    if(!canOperate()||app.connection!=='pending')return;
    app.observation.stopped=false;app.observation.stopReason=null;app.observation.expires=Date.now()+connectionBudget;
    readSyntheticConnection();render();
    if(app.connection==='pending'){
      $('[data-action="connection-stop"]')?.focus();
      announce('Read-only updates resumed for the same connection. No result was submitted.');
    }
  }
  if(action==='review-connection-refresh'){
    if(!isAdmin()||!['expired','launch-expired'].includes(observedConnectionState()))return;
    const original=app.connectionId;
    openDialog('Review a fresh connection authorization',`<p>The earlier operation ${esc(original)} stays unchanged. Its expired command and evidence remain invalid.</p><p>Authorize a new Windows handoff for Jordan Davis in the same synthetic Contoso tenant. This does not create a DLP policy, enable an agent or repeat the completed result.</p>`,'Confirm new connection authorization',()=>{
      if(!isAdmin()||app.connectionId!==original||!['expired','launch-expired'].includes(observedConnectionState())){closeDialog();return;}
      app.previousConnectionId=original;app.connectionAuthorizations=(app.connectionAuthorizations||0)+1;
      app.connectionId=`UX-DEMO-CONNECTION-REFRESH-${app.connectionAuthorizations}`;
      app.connection='waiting';app.connectionReadback='pending';app.connectionCompleted=false;app.inventory='expired';
      app.inventoryGeneration=`synthetic-inventory-refresh-${app.connectionAuthorizations}`;
      app.launchExpiresAt=Date.now()+15*60*1000;app.observation=observationFixture();app.connectionContextReadback=connectionContextFixture();
      closeDialog();render(true);
    });
  }
  if(action==='use-synthetic-companion'){
    const input=$('#prototype-companion-output');input.value=syntheticCompanionResult;input.dispatchEvent(new Event('input',{bubbles:true}));input.focus();
  }
  if(action==='companion-review'){
    if(!isAdmin()||observedConnectionState()!=='waiting'||$('#prototype-companion-output')?.value.trim()!==syntheticCompanionResult)return;
    const original=app.connectionId;
    openDialog('Submit companion evidence for verification?',`<p>The result is from the intended Contoso administrator, Jordan Davis. This separate approval continues ${esc(original)} while the Gateway checks its own configured app access.</p><p>No download, sign-in or service call is performed in this prototype. Submission does not enable DLP.</p>`,'Simulate result submission',()=>{
      if(!isAdmin()||app.connectionId!==original||observedConnectionState()!=='waiting'){closeDialog();return;}
      app.connection='pending';app.connectionReadback='pending';app.connectionCompleted=false;app.connectionSubmissions++;
      app.observation=observationFixture();app.connectionContextReadback=connectionContextFixture();app.fixture='success';closeDialog();render(true);announce('Companion result received. Checking Gateway access.');
    });
  }
  if(['connection-verified','connection-context-expired','connection-failed'].includes(action)){
    if(!isAdmin()||app.connection!=='pending')return;
    app.connectionReadback=action==='connection-failed'?'failed':'connected';
    const context=connectionContextFixture(), expired=action==='connection-context-expired';
    if(app.connectionReadback==='connected'){
      context.connectionCompleted=true;context.inventory=expired?'expired':'current';
      context.connectionVerifiedAt=Date.now()-(expired?16*60*1000:0);
      context.connectionValidUntil=Date.now()+(expired?0:15*60*1000);
    }
    app.connectionContextReadback=context;
    announce('Synthetic readback prepared. The next GET-only status check will observe it.');
  }
  if(action==='save-defaults'){
    app.defaults={agent365:$('#default-agent365').checked,monitor:$('#default-monitor').checked};
    if(!app.draft.name){app.draft.agent365=app.defaults.agent365;app.draft.azureMonitor=app.defaults.monitor;}
    toast('Defaults saved for future registrations. Existing agents are unchanged.');
  }
  if(action==='review-installation'){if(!$('#install-review').checked){toast('Review and acknowledge the installation choices first.');$('#install-review').focus();return;}openDialog('Confirm this installation plan','<p>Destination: Contoso development lab, Korea Central.</p><p>Install the reviewed Gateway resources and prepare the selected capabilities. Policy configuration and agent registration happen after deployment.</p><p class="small-text">Prototype only: this action changes local screen state.</p>','Confirm reviewed plan',()=>{app.installer='deploying';closeDialog();render(true);});}
  if(action==='installer-status'){app.installer='verified';render(true);}
  if(action==='review-resume')openDialog('Review the remaining deployment steps','<p>Completed foundation and identity steps remain preserved. Resume only after correcting the stopped capacity issue and validating the accepted checkpoint.</p>','Confirm remaining steps',()=>{app.fixture='success';app.installer='deploying';closeDialog();render(true);});
});
$('#dialog').addEventListener('keydown',event=>{
  if(event.key!=='Tab')return;
  const controls=[...event.currentTarget.querySelectorAll('button, a[href], input, select, textarea, [tabindex]')]
    .filter(element=>!element.disabled&&element.tabIndex>=0&&element.getClientRects().length);
  const first=controls[0], last=controls.at(-1);
  if(event.shiftKey&&document.activeElement===first){
    event.preventDefault();last.focus();
  }else if(!event.shiftKey&&document.activeElement===last){
    event.preventDefault();first.focus();
  }
});
$('#dialog').addEventListener('cancel',event=>{event.preventDefault();closeDialog();});
$('#fixture-reset').addEventListener('click',()=>{if($('#dialog').open)closeDialog();stopConnectionObservation();app=initial();navigate('/dashboard');toast('Prototype reset. All data is synthetic.');});
window.addEventListener('hashchange',()=>{const route=location.hash.slice(1)||'/dashboard';if(!route.startsWith('/'))return;const previous=app.route+(app.routeQuery?'?'+app.routeQuery:'');if(route!==previous){history.replaceState(null,'',`#${previous}`);go(route);}});
window.addEventListener('pagehide',stopConnectionObservation);
app=initial();navigate(location.hash.slice(1)||'/dashboard',false);
