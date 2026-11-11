import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";
import Components from "unplugin-vue-components/vite";
import { ElementPlusResolver } from "unplugin-vue-components/resolvers";
import { resolve } from "node:path";

// Deployments set the public origin so share images have absolute URLs.
process.env.VITE_SHARE_ORIGIN ??= "";
export default defineConfig({
  plugins: [
    vue(),
    Components({ resolvers: [ElementPlusResolver()], dts: false }),
  ],
  build: {
    rollupOptions: {
      input: {
        index: resolve(__dirname, "index.html"),
        share: resolve(__dirname, "share.html"),
      },
      output: {
        entryFileNames: chunk => chunk.name === "share" ? "share-entry.js" : "assets/[name]-[hash].js",
      },
    },
  },
  server: { proxy: { "/api": "http://127.0.0.1:8000" } },
});
