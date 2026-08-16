import { ProxyOptions, defineConfig, loadEnv } from "vite";
import topLevelAwait from "vite-plugin-top-level-await";

export default defineConfig(({mode}) => {
  const env = loadEnv(mode, process.cwd());
  const inferenceKey = process.env.PERSONAPLEX_INFERENCE_KEY;
  const upstreamBasePath = env.VITE_QUEUE_API_BASE_PATH?.replace(/\/$/, "");
  const stripApiPrefix = env.VITE_QUEUE_API_STRIP_PREFIX === "true";
  const proxyConf:Record<string, string | ProxyOptions> = env.VITE_QUEUE_API_URL ? {
    "/api": {
      target: env.VITE_QUEUE_API_URL,
      changeOrigin: true,
      ws: true,
      ...(upstreamBasePath || stripApiPrefix ? {
        rewrite: (path: string) => {
          const upstreamPath = stripApiPrefix
            ? path.replace(/^\/api(?=\/|$)/, "")
            : path;
          return `${upstreamBasePath ?? ""}${upstreamPath}`;
        },
      } : {}),
      ...(env.VITE_PROXY_DEBUG === "true" ? {
        configure: (proxy: { on: (event: string, callback: (error: Error) => void) => void }) => {
          proxy.on("error", (error) => console.error("PersonaPlex upstream proxy error:", error.message));
          proxy.on("proxyReqWs", () => console.log("PersonaPlex WebSocket proxy request sent"));
          proxy.on("open", () => console.log("PersonaPlex upstream WebSocket opened"));
        },
      } : {}),
      // This is evaluated by Vite's local development server only.  Do not use
      // a VITE_ prefix here: that would expose the Verda key to the browser.
      ...(inferenceKey ? { headers: { Authorization: `Bearer ${inferenceKey}` } } : {}),
    },
  } : {};
  return {
    server: {
      // Keep the authenticated development proxy on this Mac only. Localhost
      // is a secure context for microphone access, so TLS files are optional.
      host: "127.0.0.1",
      https: env.VITE_USE_HTTPS === "true" ? {
        cert: "./cert.pem",
        key: "./key.pem",
      } : undefined,
      proxy:{
        ...proxyConf,
      }
    },
    plugins: [
      topLevelAwait({
        // The export name of top-level await promise for each chunk module
        promiseExportName: "__tla",
        // The function to generate import names of top-level await promise in each chunk module
        promiseImportName: i => `__tla_${i}`,
      }),
    ],
  };
});
