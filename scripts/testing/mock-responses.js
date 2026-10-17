// Fake Responses endpoint for failure-path experiments.
// usage: node mock.js <port> <mode> [status] [body]
//   mode=status : reply <status> with <body>
//   mode=hang   : accept the request and never respond
//   mode=sse-hang : send SSE headers + one keepalive comment, then nothing
const http = require("http");
const [port, mode, status = "429", body = '{"error":{"code":"1302","message":"rate limit"}}'] = process.argv.slice(2);
let n = 0;
http.createServer((req, res) => {
  n++;
  console.log(new Date().toISOString(), "req", n, req.method, req.url);
  req.resume();
  if (mode === "status") { res.writeHead(+status, { "content-type": "application/json" }); res.end(body); }
  else if (mode === "sse-hang") { res.writeHead(200, { "content-type": "text/event-stream" }); res.write(": hi\n\n"); }
  // hang: do nothing
}).listen(+port, "127.0.0.1", () => console.log("listening", port, mode));
