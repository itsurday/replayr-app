// Adds expect(element).toBeAccessible(), Salesforce's automated accessibility check (axe), to every Jest test
const { registerSa11yMatcher } = require('@sa11y/jest');

registerSa11yMatcher();
