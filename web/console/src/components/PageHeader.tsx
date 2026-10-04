import { ReactNode } from "react";
export function PageHeader({ title, subtitle, actions }: { title: string; subtitle?: string; actions?: ReactNode }) {
  return <div className="page-header"><div className="page-heading"><h1>{title}</h1>{subtitle && <p>{subtitle}</p>}</div>
    {actions && <div className="page-actions">{actions}</div>}</div>;
}
