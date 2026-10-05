import { Routes, Route, Navigate, useLocation } from "react-router-dom";
import { useQueryClient } from "@tanstack/react-query";
import { AppShell } from "./components/AppShell";
import { Home } from "./pages/Home";
import { AgentsList } from "./pages/agents/AgentsList";
import { AgentDetail } from "./pages/agents/AgentDetail";
import { RegisterAgent } from "./pages/agents/RegisterAgent";
import { Connection } from "./pages/dataprotection/Connection";
import { Policies } from "./pages/dataprotection/Policies";
import { Platform } from "./pages/Platform";
import { AgentDeletion } from "./pages/AgentDeletion";
import { RouteErrorBoundary } from "./components/RouteErrorBoundary";

export function App() {
  const location = useLocation();
  const queryClient = useQueryClient();
  return (
    <AppShell>
      <RouteErrorBoundary key={location.pathname} onReset={() => { void queryClient.resetQueries(); }}>
        <Routes>
        <Route path="/" element={<Home />} />
        <Route path="/agents" element={<AgentsList />} />
        <Route path="/agents/:id" element={<AgentDetail />} />
        <Route path="/register" element={<RegisterAgent />} />
        <Route path="/data-protection" element={<Navigate to="/data-protection/policies" replace />} />
        <Route path="/data-protection/connection" element={<Navigate to={`/settings/purview${location.search}${location.hash}`} replace />} />
        <Route path="/data-protection/classifiers" element={<Navigate to="/data-protection/policies" replace />} />
        <Route path="/data-protection/policies" element={<Policies />} />
        <Route path="/settings" element={<Platform />} />
        <Route path="/settings/agents" element={<AgentDeletion />} />
        <Route path="/settings/purview" element={<Connection />} />
        <Route path="/platform" element={<Navigate to={`/settings${location.search}${location.hash}`} replace />} />
        <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </RouteErrorBoundary>
    </AppShell>
  );
}
