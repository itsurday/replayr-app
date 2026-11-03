// Runs as the user set in the admin's PlatformEventSubscriberConfig (admin guide); all logic is in WorkWaiting
trigger ReplayrWorkWaitingTrigger on Replayr_Work_Waiting__e(after insert) {
    WorkWaiting.handle();
}
