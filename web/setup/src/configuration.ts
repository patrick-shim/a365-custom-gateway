export interface Configuration {
  deployProfile: 'runtime'; tenantId: string; environment: 'dev'|'staging'|'prod'; projectName: string;
  subscriptionId?: string; location?: string; resourceGroupName?: string;
  runtime: {apiHostPort:number;consoleHostPort:number;composeProjectName?:string;credentialLabelPrefix?:string};
  agent365: {seedBlueprintName:string;allowDevelopmentRegistryPreview:boolean;registryBetaAcknowledged:boolean;reviewedManagerApplicationIds:string[]};
  promptShield: {enabled:boolean;skuName:'F0'|'S0';costAndQuotaAcknowledged:boolean};
  purview: {enabled:boolean;authorityRequirementsAcknowledged:boolean};
}
export const defaults: Configuration = {
  deployProfile:'runtime',tenantId:'',environment:'dev',projectName:'a365gw',
  runtime:{apiHostPort:5080,consoleHostPort:5081},
  agent365:{seedBlueprintName:'A365 Gateway a365gw dev',allowDevelopmentRegistryPreview:false,registryBetaAcknowledged:false,reviewedManagerApplicationIds:[]},
  promptShield:{enabled:false,skuName:'F0',costAndQuotaAcknowledged:false},
  purview:{enabled:false,authorityRequirementsAcknowledged:false}
};
// This only removes disabled fields for schema submission. The PowerShell engine
// performs authoritative validation, including tenant IDs, consent and ports.
export function submission(value: Configuration): Configuration {
  const config=structuredClone(value);
  if(!config.promptShield.enabled) { delete config.subscriptionId;delete config.location;delete config.resourceGroupName;config.promptShield.costAndQuotaAcknowledged=false; }
  if(!config.purview.enabled) config.purview.authorityRequirementsAcknowledged=false;
  if(config.environment!=='dev') config.agent365.allowDevelopmentRegistryPreview=false;
  if(!config.agent365.allowDevelopmentRegistryPreview) config.agent365.registryBetaAcknowledged=false;
  return config;
}
