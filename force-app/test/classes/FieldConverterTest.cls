/**
 * Uses standard fields for each type, so no records or permission sets are needed: conversion reads
 * field descriptions only.
 */
@IsTest
private with sharing class FieldConverterTest {
    private static Object convert(Object value, String objectName, String fieldName) {
        return FieldConverter.convert(value, FieldConverter.field(objectName, fieldName));
    }

    private static String errorFor(Object value, String objectName, String fieldName) {
        try {
            convert(value, objectName, fieldName);
        } catch (FieldConverter.ConversionException e) {
            return e.getMessage();
        }
        return null;
    }

    private static Id fakeId(Schema.SObjectType objectType) {
        return Id.valueOf(objectType.getDescribe(SObjectDescribeOptions.DEFERRED).getKeyPrefix() + '000000000001');
    }

    @IsTest
    static void convertsEachSupportedType() {
        Assert.areEqual('Acme', convert('Acme', 'Account', 'Name'), 'Text');
        Assert.areEqual('42', convert(42, 'Account', 'Name'), 'Number into text');
        Assert.areEqual('Hot', convert('Hot', 'Account', 'Rating'), 'Picklist');
        Assert.areEqual(250, convert(250, 'Account', 'NumberOfEmployees'), 'Whole number');
        Assert.areEqual(250, convert('250', 'Account', 'NumberOfEmployees'), 'Numeric text into whole number');
        Assert.areEqual(1500000.50, convert(1500000.50, 'Opportunity', 'Amount'), 'Currency with cents');
        Assert.areEqual(9999999999L, convert(9999999999L, 'Opportunity', 'Amount'), 'Long into currency');
        Assert.areEqual(true, convert(true, 'Contact', 'DoNotCall'), 'Checkbox');
        Assert.areEqual(false, convert('FALSE', 'Contact', 'DoNotCall'), 'Checkbox from text');
        Assert.areEqual(Date.newInstance(1990, 5, 17), convert('1990-05-17', 'Contact', 'Birthdate'), 'Date');
        Assert.areEqual(Time.newInstance(9, 5, 0, 0), convert('09:05', 'BusinessHours', 'MondayStartTime'), 'Time');
        Assert.areEqual(
            Time.newInstance(9, 5, 7, 250),
            convert('09:05:07.25', 'BusinessHours', 'MondayStartTime'),
            'Time with seconds and milliseconds'
        );
        Id accountId = fakeId(Account.SObjectType);
        Assert.areEqual(accountId, convert(String.valueOf(accountId).left(15), 'Contact', 'AccountId'), 'Lookup');
    }

    @IsTest
    static void convertsDateTimesWithATimeZone() {
        Datetime expected = Datetime.newInstanceGmt(2026, 10, 27, 12, 30, 0);
        Map<String, Object> accepted = new Map<String, Object>{
            'UTC' => '2026-10-27T12:30:00Z',
            'offset with colon' => '2026-10-27T14:30:00+02:00',
            'offset without colon' => '2026-10-27T14:30:00+0200',
            'no seconds' => '2026-10-27T12:30Z',
            'fractional seconds' => '2026-10-27T12:30:00.000Z',
            'milliseconds since 1970' => expected.getTime()
        };

        for (String form : accepted.keySet()) {
            Assert.areEqual(expected, convert(accepted.get(form), 'Event', 'ActivityDateTime'), form);
        }
    }

    @IsTest
    static void rejectsDateTimesThatWouldDependOnTheUsersTimeZoneOrUnit() {
        Map<String, Object> rejected = new Map<String, Object>{
            'no time zone' => '2026-10-27T14:30:00',
            'date only' => '2026-10-27',
            'epoch seconds, not milliseconds' => 1700000000,
            'words' => 'yesterday'
        };

        for (String form : rejected.keySet()) {
            Assert.isNotNull(errorFor(rejected.get(form), 'Event', 'ActivityDateTime'), 'Rejected: ' + form);
        }
    }

    @IsTest
    static void emptyTextClearsNonTextFieldsAndStaysEmptyInTextFields() {
        Assert.isNull(convert(null, 'Opportunity', 'Amount'), 'Null clears');
        Assert.isNull(convert('', 'Opportunity', 'Amount'), 'Empty text clears a number field');
        Assert.isNull(convert('', 'Contact', 'Birthdate'), 'Empty text clears a date field');
        Assert.isNull(convert('   ', 'Opportunity', 'Amount'), 'Blank text clears a number field');
        Assert.areEqual('', convert('', 'Account', 'Name'), 'Empty text stays empty in a text field');
    }

    @IsTest
    static void rejectsMoreDecimalsOrDigitsThanTheFieldAllows() {
        Assert.isTrue(errorFor(10.5, 'Account', 'AnnualRevenue').contains('allows 0 decimal places'), 'No decimals field');
        Assert.isTrue(errorFor(1.005, 'Opportunity', 'Amount').contains('allows 2 decimal places'), 'Two decimals field');
        Assert.isTrue(errorFor(1000, 'Opportunity', 'Probability').contains('digits before the decimal point'), 'Too big');
        Assert.areEqual(0.5, convert(0.5, 'Opportunity', 'Amount'), 'Below 1 is fine');
        Assert.areEqual(-12.25, convert(-12.25, 'Opportunity', 'Amount'), 'Negative is fine');
    }

    @IsTest
    static void wholeNumbersStayInRange() {
        Assert.areEqual(2147483647, convert(2147483647L, 'Account', 'NumberOfEmployees'), 'Largest');
        Assert.isNotNull(errorFor(2147483648L, 'Account', 'NumberOfEmployees'), 'One too large');
        Assert.isNotNull(errorFor(Decimal.valueOf('1e30'), 'Account', 'NumberOfEmployees'), 'Huge');
        Assert.isNotNull(errorFor('abc', 'Account', 'NumberOfEmployees'), 'Text');
    }

    @IsTest
    static void lookupIdsMustBelongToTheTargetObject() {
        String message = errorFor(String.valueOf(fakeId(Contact.SObjectType)), 'Contact', 'AccountId');

        Assert.isTrue(message.contains('expects the Id of a record of an allowed object'), message);
    }

    @IsTest
    static void mismatchesNameTheFieldAndTypeButNeverTheValue() {
        Map<String, List<Object>> cases = new Map<String, List<Object>>{
            'AnnualRevenue expects a number, got text' => new List<Object>{ 'secret-abc', 'Account', 'AnnualRevenue' },
            'DoNotCall expects true or false, got text' => new List<Object>{ 'secret-yes', 'Contact', 'DoNotCall' },
            'Birthdate expects a date' => new List<Object>{ '17/05/1990-secret', 'Contact', 'Birthdate' },
            'ActivityDateTime expects a date and time' => new List<Object>{ 'secret-tomorrow', 'Event', 'ActivityDateTime' },
            'MondayStartTime expects a time' => new List<Object>{ 'secret-25:00', 'BusinessHours', 'MondayStartTime' },
            'AccountId expects a Salesforce record Id' => new List<Object>{ 'secret-not-an-id', 'Contact', 'AccountId' },
            'Name expects text, got an object' => new List<Object>{
                new Map<String, Object>{ 'secret' => 1 },
                'Account',
                'Name'
            }
        };

        for (String expected : cases.keySet()) {
            List<Object> input = cases.get(expected);
            String message = errorFor(input[0], (String) input[1], (String) input[2]);
            Assert.isNotNull(message, 'Rejected: ' + expected);
            Assert.isTrue(message.contains(expected), 'Message "' + message + '" contains "' + expected + '"');
            Assert.isFalse(message.contains('secret'), 'Never echoes the value: ' + message);
        }
    }

    @IsTest
    static void rejectsImpossibleDatesAndTimes() {
        Assert.isNotNull(errorFor('2026-02-30', 'Contact', 'Birthdate'), 'February 30th');
        Assert.isNotNull(errorFor('09:60', 'BusinessHours', 'MondayStartTime'), 'Minute 60');
        Assert.isNotNull(errorFor('9:5', 'BusinessHours', 'MondayStartTime'), 'Single digits');
        Assert.isNotNull(errorFor(true, 'Opportunity', 'Amount'), 'True/false into a number');
    }

    @IsTest
    static void textMustFitTheFieldAndIsNeverSilentlyCut() {
        Assert.areEqual(255, ((String) convert('x'.repeat(255), 'Account', 'Name')).length(), 'Exactly at the limit');
        String message = errorFor('x'.repeat(300), 'Account', 'Name');

        Assert.isTrue(message.contains('holds at most 255 characters, got 300'), message);
    }

    @IsTest
    static void unknownObjectsFieldsAndRelationshipPathsAreRejected() {
        List<List<String>> names = new List<List<String>>{
            new List<String>{ 'NoSuchObject__c', 'Name' },
            new List<String>{ 'Account', 'NoSuchField__c' },
            new List<String>{ 'Contact', 'Account.Name' },
            new List<String>{ '', 'Name' },
            new List<String>{ null, 'Name' },
            new List<String>{ 'Account', null },
            new List<String>{ 'Account; DELETE', 'Name' },
            new List<String>{ 'Job__c', 'Status__c' }
        };

        for (List<String> pair : names) {
            try {
                FieldConverter.field(pair[0], pair[1]);
                Assert.fail('Expected rejection of ' + pair);
            } catch (FieldConverter.ConversionException e) {
                Assert.isTrue(e.getMessage().startsWith('Unknown'), e.getMessage());
            }
        }
    }

    @IsTest
    static void packageObjectsNeedTheirNamespaceAndNamesAreCaseInsensitive() {
        String jobObject = String.valueOf(Job__c.SObjectType);

        Assert.areEqual('AnnualRevenue', FieldConverter.field(' account ', ' annualrevenue ').getName(), 'Trimmed');
        Assert.areEqual(Job__c.Status__c.getDescribe().getName(), FieldConverter.field(jobObject, Job__c.Status__c.getDescribe().getName()).getName(), 'Full API names resolve');
    }

    @IsTest
    static void typesReplayrDoesNotMapYetAreRejected() {
        String message = errorFor('x', 'Account', 'BillingAddress');

        Assert.isTrue(message.contains('does not map yet'), message);
    }

    @IsTest
    static void convertsTwoHundredValuesDescribingTheFieldOnce() {
        Schema.DescribeFieldResult amount = FieldConverter.field('Opportunity', 'Amount');
        List<Object> converted = new List<Object>();

        Test.startTest();
        for (Integer i = 0; i < 200; i++) {
            converted.add(FieldConverter.convert(i + 0.5, amount));
        }
        Test.stopTest();

        Assert.areEqual(200, converted.size(), 'One value per item');
        Assert.areEqual(199.5, converted[199], 'Last value');
    }
}
