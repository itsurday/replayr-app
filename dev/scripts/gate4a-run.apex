// Dev only: the phase 4a gate. 200 new Accounts in one save; the active gate flow sends each through Replayr
List<Account> accounts = new List<Account>();
for (Integer i = 0; i < 200; i++) {
    accounts.add(new Account(Name = 'Replayr gate ' + String.valueOf(i).leftPad(3, '0')));
}
insert accounts;
System.debug(LoggingLevel.ERROR, 'GATE4A inserted=' + accounts.size() + ' at=' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\''));
