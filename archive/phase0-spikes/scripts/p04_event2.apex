// P0.4 run 2: publish the event again after PlatformEventSubscriberConfig sets the trigger's run-as user.
Database.SaveResult pub = EventBus.publish(new Spike_Event__e(Run__c = 'config'));
SpikeLog.write('P0.4 script run 2', 'event publish ok=' + pub.isSuccess() + (pub.isSuccess() ? '' : ' ' + pub.getErrors()));
