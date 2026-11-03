// Creates the test providers and endpoints in a fresh dev scratch org (docs/dev-setup.md, step 5).
// Names match the credentials in dev/main/default. No secrets: those are entered in Setup.
List<replayr__Provider__c> providers = new List<replayr__Provider__c>{
    new replayr__Provider__c(Name = 'Httpbin', replayr__Named_Credential__c = 'Httpbin_API', replayr__Key__c = 'httpbin'),
    new replayr__Provider__c(Name = 'Httpbin API key', replayr__Named_Credential__c = 'Httpbin_ApiKey_API', replayr__Key__c = 'httpbin-api-key'),
    new replayr__Provider__c(Name = 'Httpbin bearer', replayr__Named_Credential__c = 'Httpbin_Bearer_API', replayr__Key__c = 'httpbin-bearer'),
    new replayr__Provider__c(Name = 'OAuth server', replayr__Named_Credential__c = 'Oauth_Server_API', replayr__Key__c = 'oauth-server'),
    new replayr__Provider__c(Name = 'OAuth server (browser)', replayr__Named_Credential__c = 'Oauth_Server_Browser_API', replayr__Key__c = 'oauth-server-browser')
};
insert as user providers;
insert as user new List<replayr__Endpoint__c>{
    new replayr__Endpoint__c(Name = 'Get', replayr__Provider__c = providers[0].Id, replayr__Method__c = 'GET', replayr__Path__c = '/get'),
    new replayr__Endpoint__c(Name = 'Headers', replayr__Provider__c = providers[1].Id, replayr__Method__c = 'GET', replayr__Path__c = '/headers'),
    new replayr__Endpoint__c(Name = 'Bearer check', replayr__Provider__c = providers[2].Id, replayr__Method__c = 'GET', replayr__Path__c = '/bearer'),
    new replayr__Endpoint__c(Name = 'Limits', replayr__Provider__c = providers[3].Id, replayr__Method__c = 'GET', replayr__Path__c = '/services/data/v62.0/limits'),
    new replayr__Endpoint__c(Name = 'Limits (browser)', replayr__Provider__c = providers[4].Id, replayr__Method__c = 'GET', replayr__Path__c = '/services/data/v62.0/limits')
};
