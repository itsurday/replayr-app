// Lint for Replayr's Lightning web components (npm run lint), Salesforce's recommended LWC rules
const lwcConfig = require('@salesforce/eslint-config-lwc/recommended');
const jestPlugin = require('eslint-plugin-jest');

module.exports = [
    ...[].concat(lwcConfig).map((config) => ({ ...config, files: ['**/lwc/**/*.js'] })),
    {
        files: ['**/lwc/**/__tests__/**/*.js'],
        ...jestPlugin.configs['flat/recommended'],
        rules: {
            ...jestPlugin.configs['flat/recommended'].rules,
            // Tests import wire adapters to emit test data
            '@lwc/lwc/no-unexpected-wire-adapter-usages': 'off'
        }
    }
];
