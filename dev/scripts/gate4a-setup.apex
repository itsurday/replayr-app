// Dev only: the endpoint the phase 4a gate flow sends to (httpbin.org echoes the POST). Run once per scratch org
replayr__Provider__c httpbin = [SELECT Id FROM replayr__Provider__c WHERE replayr__Named_Credential__c = 'Httpbin_API' LIMIT 1];
replayr__Endpoint__c post = new replayr__Endpoint__c(
    Name = 'Post (gate 4a)',
    replayr__Key__c = 'httpbin-post',
    replayr__Provider__c = httpbin.Id,
    replayr__Method__c = 'POST',
    replayr__Path__c = '/post',
    replayr__Retry_Safe__c = true,
    replayr__Allow_Sending__c = true
);
insert as user post;
insert as user new replayr__Mapping__c(
    replayr__Endpoint__c = post.Id,
    replayr__Direction__c = 'Request',
    replayr__Target_Object__c = 'Account',
    replayr__Rules__c = '{"name": "{{Name}}", "salesforceId": "{{Id}}"}'
);
