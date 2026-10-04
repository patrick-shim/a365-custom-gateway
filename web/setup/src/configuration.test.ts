import { describe, expect, it } from 'vitest';
import { defaults, submission } from './configuration';
describe('setup submission',()=>{
  it('does not infer consent or enable integrations',()=>{
    const input=structuredClone(defaults);
    input.purview.enabled=true;input.promptShield.enabled=true;
    const result=submission(input);
    expect(result.purview.authorityRequirementsAcknowledged).toBe(false);
    expect(result.promptShield.costAndQuotaAcknowledged).toBe(false);
  });
  it('removes unused Azure inputs for tenant-only setup without changing the form',()=>{
    const input={...structuredClone(defaults),subscriptionId:'stale',location:'stale',resourceGroupName:'stale'};
    expect(submission(input).subscriptionId).toBeUndefined();
    expect(input.subscriptionId).toBe('stale');
  });
  it('keeps preview disabled outside development',()=>{
    const input=structuredClone(defaults);input.environment='prod';
    input.agent365.allowDevelopmentRegistryPreview=true;input.agent365.registryBetaAcknowledged=true;
    expect(submission(input).agent365.allowDevelopmentRegistryPreview).toBe(false);
    expect(submission(input).agent365.registryBetaAcknowledged).toBe(false);
  });
});
