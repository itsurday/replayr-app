/**
 * The console's Providers and endpoints section: lists providers with their endpoints. For
 * Replayr Admins and Operators (Replayr_Manage_Jobs), read in user mode. It writes nothing: providers and endpoints
 * are viewed, edited and created through the standard record forms (Lightning Data Service), so the platform
 * enforces field access and the validation rules (decisions.md, ADR-024).
 */
public with sharing class ConsoleSetup {
    // Far more than an org configures; the list says when it is cut
    @TestVisible
    private static final Integer MAX_PROVIDERS = 200;

    /** One endpoint under its provider. */
    public class EndpointRow {
        @AuraEnabled
        public Id id;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String key;
        @AuraEnabled
        public String method;
        @AuraEnabled
        public String path;
        @AuraEnabled
        public Boolean retrySafe;
        @AuraEnabled
        public Boolean allowSending;
    }

    /** One provider with its endpoints. */
    public class ProviderRow {
        @AuraEnabled
        public Id id;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String key;
        @AuraEnabled
        public String namedCredential;
        @AuraEnabled
        public List<EndpointRow> endpoints = new List<EndpointRow>();
    }

    /** The section's content. */
    public class Setup {
        @AuraEnabled
        public List<ProviderRow> providers = new List<ProviderRow>();
        /** More providers exist than are listed. */
        @AuraEnabled
        public Boolean cut = false;
        /** Whether the person may create providers and endpoints (Replayr Admins): the New buttons. */
        @AuraEnabled
        public Boolean canCreateProviders = false;
        @AuraEnabled
        public Boolean canCreateEndpoints = false;
    }

    /**
     * Lists providers by name, each with its endpoints by name.
     * @return the providers
     */
    @AuraEnabled
    public static Setup providers() {
        if (!FeatureManagement.checkPermission(JobActions.PERMISSION)) {
            throw ConsoleError.of('You need the Replayr Admin or Replayr Operator permission set.');
        }
        try {
            List<Provider__c> providers = [
                SELECT
                    Id, Name, Key__c, Named_Credential__c,
                    (SELECT Id, Name, Key__c, Method__c, Path__c, Retry_Safe__c, Allow_Sending__c FROM Endpoints__r ORDER BY Name)
                FROM Provider__c
                WITH USER_MODE
                ORDER BY Name
                LIMIT :MAX_PROVIDERS + 1
            ];
            Setup setup = new Setup();
            setup.cut = providers.size() > MAX_PROVIDERS;
            for (Integer i = 0; i < Math.min(providers.size(), MAX_PROVIDERS); i++) {
                setup.providers.add(toRow(providers[i]));
            }
            setup.canCreateProviders = Schema.SObjectType.Provider__c.isCreateable();
            setup.canCreateEndpoints = Schema.SObjectType.Endpoint__c.isCreateable();
            return setup;
        } catch (Exception e) {
            // Only the type: a query error can name fields and objects
            throw ConsoleError.of('Replayr couldn\'t read providers (' + e.getTypeName() + '): check your Replayr permission set.');
        }
    }

    private static ProviderRow toRow(Provider__c provider) {
        ProviderRow row = new ProviderRow();
        row.id = provider.Id;
        row.name = provider.Name;
        row.key = provider.Key__c;
        row.namedCredential = provider.Named_Credential__c;
        for (Endpoint__c endpoint : provider.Endpoints__r) {
            EndpointRow endpointRow = new EndpointRow();
            endpointRow.id = endpoint.Id;
            endpointRow.name = endpoint.Name;
            endpointRow.key = endpoint.Key__c;
            endpointRow.method = endpoint.Method__c;
            endpointRow.path = endpoint.Path__c;
            endpointRow.retrySafe = endpoint.Retry_Safe__c;
            endpointRow.allowSending = endpoint.Allow_Sending__c;
            row.endpoints.add(endpointRow);
        }
        return row;
    }
}
