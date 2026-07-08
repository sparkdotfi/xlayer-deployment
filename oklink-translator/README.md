# OKLink Translator Server

A simple Node.js HTTPS server designed to intercept, log, and translate explorer API calls that `forge verify-bytecode` issues. This helps in inspecting incoming request structures so that translations and reshaping for OKLink can be implemented correctly.

## Features

- **HTTPS Support**: Uses local self-signed SSL/TLS certificates (`key.pem` and `cert.pem`).
- **Comprehensive Logging**: Outputs every incoming request's method, original URL, headers, query parameters, and body.
- **Proxy and Translation**: Intercepts explicitly handled routes, requests them from `https://www.oklink.com/api/v5/` (attaching the `Ok-Access-Key` if configured), logs OKLink's response, and reshapes/forwards it to the client.
- **Fallback Rejection**: Rejects any unhandled routes with a `400 Bad Request` while still logging the incoming request details.

## Getting Started

1. **Install Dependencies**:

    ```bash
    npm install
    ```

2. **Configure Environment**:
   Rename or copy `.env.example` to `.env` and set your `OKLINK_API_KEY`:

    ```bash
    cp .env.example .env
    # Edit .env to add OKLINK_API_KEY
    ```

3. **Generate SSL Certificates**:
   Certificates are auto-generated on server start if they do not exist. To manually generate them:

    ```bash
    node generate-certs.js
    ```

4. **Start the Server**:
   By default, the server starts in **HTTP mode** (recommended for local testing with `forge` to bypass TLS certificate checks):

    ```bash
    npm start
    ```

    To run the server in **HTTPS mode** (using self-signed certificates):

    ```bash
    npm run start:https
    ```

    The server will start listening on port `8443` (or the configured `PORT`).

## Testing the Server

If running in HTTP mode:

### Test Handled Route (Proxy/Translation)

This proxies to the OKLink endpoint (`https://www.oklink.com/api/v5/explorer/contract/get-source-code`):

```bash
curl "http://localhost:8443/api/get-code/0x83A914C361bB729EB6BEBC8C7bA993667A0E6Df8"
```

### Test Unhandled Route (Fallback)

```bash
curl -X POST "http://localhost:8443/api/v5/explorer/contract/verify-contract-info" \
     -H "Content-Type: application/json" \
     -d '{"address":"0x83A914C361bB729EB6BEBC8C7bA993667A0E6Df8"}'
```

If running in HTTPS mode, use the `https://` protocol and add `-k` or `--insecure` to the curl command to allow the self-signed certificates:

```bash
curl -k "https://localhost:8443/api/get-code/0x83A914C361bB729EB6BEBC8C7bA993667A0E6Df8"
```

## Formatting and Linting

We use **Prettier** for formatting (configured with a 4-space tabWidth and double quotes) and **ESLint** for static code analysis.

- **Check Linting**:
    ```bash
    npm run lint
    ```
- **Format Code**:
    ```bash
    npm run format
    ```
