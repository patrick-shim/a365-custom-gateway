export const purviewConnectionQueryKey = ["purview-connection"] as const;
export const purviewPolicyCatalogQueryKey = ["purview-policy-catalog"] as const;

export function purviewConnectorOperationQueryKey(operationId: string) {
  return ["purview-connector-operation", operationId] as const;
}
