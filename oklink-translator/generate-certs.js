const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const KEY_FILE = path.join(__dirname, "key.pem");
const CERT_FILE = path.join(__dirname, "cert.pem");

function generateCerts() {
    if (fs.existsSync(KEY_FILE) && fs.existsSync(CERT_FILE)) {
        console.log(
            "SSL Certificates (key.pem, cert.pem) already exist. Skipping generation.",
        );
        return;
    }

    console.log("Generating self-signed SSL certificates...");
    try {
        // Generate key.pem and cert.pem valid for 365 days
        execSync(
            `openssl req -x509 -newkey rsa:2048 -keyout "${KEY_FILE}" -out "${CERT_FILE}" -sha256 -days 365 -nodes -subj "/CN=localhost"`,
            { stdio: "inherit" },
        );
        console.log("Self-signed SSL certificates generated successfully.");
    } catch (error) {
        console.error("Error generating SSL certificates:", error.message);
        process.exit(1);
    }
}

if (require.main === module) {
    generateCerts();
}

module.exports = generateCerts;
