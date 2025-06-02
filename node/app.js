const http = require('http');
const os = require('os');

const server = http.createServer((req, res) => {
    const hostname = os.hostname();
    res.writeHead(200, { 'Content-Type': 'text/html' });
    res.end(`<h1>Hello from Node.js!</h1><p>Hostname: ${hostname}</p>`);
});

const PORT = 3000;
server.listen(PORT, () => {
    const hostname = os.hostname();
    console.log(`Server running on http://localhost:${PORT}`);
    console.log(`Hostname: ${hostname}`);
});
