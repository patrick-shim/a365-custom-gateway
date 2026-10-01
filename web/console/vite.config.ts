import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// The Console is a static SPA that talks to the Gateway REST API.
// In development it proxies /api to the backend defined by GATEWAY_API_BASE_URL.
export default defineConfig(() => ({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: process.env.GATEWAY_API_BASE_URL
      ? {
          "/api": {
            target: process.env.GATEWAY_API_BASE_URL,
            changeOrigin: true,
            secure: true,
          },
        }
      : undefined,
  },
  build: {
    outDir: "dist",
    sourcemap: true,
  },
}));
