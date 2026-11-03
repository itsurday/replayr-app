// Unit tests for Replayr's Lightning web components (npm run test:unit)
const { jestConfig } = require('@salesforce/sfdx-lwc-jest/config');

module.exports = {
    ...jestConfig,
    moduleNameMapper: {
        ...jestConfig.moduleNameMapper,
        // Not stubbed by sfdx-lwc-jest
        '^lightning/modal$': '<rootDir>/jest-mocks/lightning/modal'
    },
    modulePathIgnorePatterns: ['<rootDir>/.localdevserver', '<rootDir>/archive'],
    // toBeAccessible() (@sa11y/jest) in every test
    setupFilesAfterEnv: ['<rootDir>/jest-sa11y-setup.js'],
    // Every component counts, so one without tests shows as 0% rather than not at all
    collectCoverageFrom: ['force-app/**/lwc/**/*.js', '!**/__tests__/**']
};
