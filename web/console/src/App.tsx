import { Routes, Route, Navigate, useLocation } from "react-router-dom";
import { useQueryClient } from "@tanstack/react-query";
import { AppShell } from "./components/AppShell";
import { Home } from "./pages/Home";
import { AgentsList } from "./pages/agents/AgentsList";
import { AgentDetail } from "./pages/agents/AgentDetail";
import { RegisterAgent } from "./pages/agents/RegisterAgent";
import { Connection } from "./pages/dataprotection/Connection";
import { Classifiers } from "./pages/dataprotection/Classifiers";
import { Policies } from "./pages/dataprotection/Policies";
import { Platform } from "./pages/Platform";
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
        <Route path="/data-protection" element={<Navigate to="/data-protection/connection" replace />} />
        <Route path="/data-protection/connection" element={<Connection />} />
        <Route path="/data-protection/classifiers" element={<Classifiers />} />
        <Route path="/data-protection/policies" element={<Policies />} />
        <Route path="/platform" element={<Platform />} />
        <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </RouteErrorBoundary>
    </AppShell>
  );
}
