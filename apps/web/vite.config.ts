import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { securityHeaders } from "./security-headers.js";

export default defineConfig({
  preview: { headers: securityHeaders },
  build: {
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (/node_modules\/(?:@tiptap|prosemirror-|marked)/.test(id))
            return "editor";
        },
      },
    },
  },
  plugins: [
    react(),
    {
      name: "production-security-headers",
      apply: "build",
      generateBundle() {
        this.emitFile({
          type: "asset",
          fileName: "_headers",
          source:
            "/*\n" +
            Object.entries({
              ...securityHeaders,
              "Strict-Transport-Security": "max-age=31536000",
            })
              .map(([name, value]) => `  ${name}: ${value}\n`)
              .join(""),
        });
      },
    },
  ],
});
