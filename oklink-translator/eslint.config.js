const js = require("@eslint/js");
const prettier = require("eslint-config-prettier");

module.exports = [
    {
        ignores: ["node_modules/**", "*.pem"],
    },
    js.configs.recommended,
    prettier,
    {
        languageOptions: {
            ecmaVersion: 2022,
            sourceType: "commonjs",
            globals: {
                // Node.js environment globals
                process: "readonly",
                __dirname: "readonly",
                require: "readonly",
                module: "readonly",
                exports: "readonly",
                console: "readonly",
                fetch: "readonly",
            },
        },
        rules: {
            "no-unused-vars": "warn",
            "no-console": "off",
            "no-undef": "error",
        },
    },
];
