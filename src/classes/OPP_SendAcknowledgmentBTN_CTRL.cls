/*
    Copyright (c) 2015 Salesforce.org
    All rights reserved.
    
    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:
    
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of Salesforce.org nor the names of
      its contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.
 
    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT 
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS 
    FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE 
    COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, 
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, 
    BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; 
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER 
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT 
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN 
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE 
    POSSIBILITY OF SUCH DAMAGE.
*/
/**
* @author Salesforce.org
* @date 2015
* @group Opportunity
* @description Visualforce controller for the Send Acknowledgment buttons (single and list view) on Opportunities.  
*/
public with sharing class OPP_SendAcknowledgmentBTN_CTRL {

    /*******************************************************************************************************
    * @description Acknowledgement Status Picklist API Names
    */
    @TestVisible
    private static final String ACKNOWLEDGED = 'Acknowledged';
    @TestVisible
    private static final String ACKNOWLEDGEMENT_READY_TO_EMAIL = 'Email Acknowledgment Now';
    @TestVisible
    private static final String ACKNOWLEDGEMENT_FAILED = 'Email Acknowledgment Not Sent';

    /*******************************************************************************************************
    * @description the id to return the user to or first object prefix for the list actions
    */
    public String recordId { get; set; }

    /*******************************************************************************************************
    * @description set to true when user should be returned to previous page via javascript
    */
    public Boolean redirect { get; set; }

    /*******************************************************************************************************
    * @description List of Opportunities that should receive email acknowledgements 
    */
    @TestVisible
    private List<Opportunity> oppsToAcknowledge { 
        get {
            if (oppsToAcknowledge == null) {
                oppsToAcknowledge = [
                    SELECT Acknowledgment_Status__c 
                    FROM Opportunity
                    WHERE Id IN :oppIds
                ]; 
            }
            return oppsToAcknowledge;
        }
        set; 
    }

    /*******************************************************************************************************
    * @description Ids of Opportunities that should receive email acknowledgements
    */
    private Set<Id> oppIds = new Set<Id>();

    /*******************************************************************************************************
    * @description the list of Opportunities that were not acknowledged
    */
    public List<Opportunity> oppsNotSent { get; set; }

    /*******************************************************************************************************
    * @description the count of Opportunities that were acknowledged
    */
    public Integer sentCount { get; set; }

    /*******************************************************************************************************
    * @description the count of Opportunities where acknowledgements were already sent
    */
    public Integer alreadySentCount { get; set; }

    /*******************************************************************************************************
    * @description the count of Opportunities that were NOT acknowledged
    */
    public Integer notSentCount { get; set; }

    /*******************************************************************************************************
    * @description Page constructor that takes the set controller
    * @param controller The set controller
    * @return void
    */
    public OPP_SendAcknowledgmentBTN_CTRL(ApexPages.StandardSetController setController) {
        oppsNotSent = new List<Opportunity>(); 
        sentCount = 0;
        notSentCount = 0;
        alreadySentCount = 0;

        if (setController.getSelected().isEmpty()) {
            Id oppId = ApexPages.currentPage().getParameters().get('oppId');

            if (oppId != null) {
                oppIds.add(oppId);
                recordId = oppId;
            }

        } else {
            oppIds.addAll(
                extractIds(setController.getSelected())
            );
            recordId = Opportunity.SObjectType.getDescribe().getKeyPrefix();            
        }
    }

    /*******************************************************************************************************
    * @description Action method called when the user clicks on the Send Acknowledgment button.
    * @return null to the calling page
    */
    public PageReference SendAcknowledgment() {
        // wanted to give an error if they were going to overflow their email limit,
        // but one can only see the Apex email limits (1k/day), 
        // not the workflow email limits (1k/day per user license).
        // Integer sentCount = system.limits.getEmailInvocations();
        // Integer cLimit = system.limits.getLimitEmailInvocations();
        
        // wanted to give an error if there were no workflow rules activated on Opportunity
        // that looked at the Acknowledgment Status field.  But unfortunately one cannot 
        // use Apex to view workflows (they aren't supported in describe calls).  the 
        // workarounds are to use the metadata API, but we aren't going to invest in that for this
        // one little feature.
        
        if (oppsToAcknowledge.isEmpty()) {
            addStatusMessage(ApexPages.Severity.ERROR, System.Label.sendAcknowledgmentNoneSelected);
            return null;        
        }

        List<Opportunity> oppsToAttemptAck = new List<Opportunity>();

        //update status to ready for acknowledgement
        for (Opportunity opp : oppsToAcknowledge) {      
            if (shouldSendAck(opp)) {
                opp.Acknowledgment_Status__c = ACKNOWLEDGEMENT_READY_TO_EMAIL;
                oppsToAttemptAck.add(opp);
            } else {
                alreadySentCount++;
            }
        }

        Savepoint sp = Database.setSavepoint(); 
        try {
            update oppsToAttemptAck;
            
            // detect how many were not sent via the workflow
            oppsNotSent = [
                SELECT Name
                FROM Opportunity 
                WHERE Id IN :oppsToAttemptAck 
                AND Acknowledgment_Status__c = :ACKNOWLEDGEMENT_READY_TO_EMAIL
            ];
            
            notSentCount = oppsNotSent.size();
            sentCount = oppsToAcknowledge.size() - notSentCount - alreadySentCount;
            
            // for those Opps that failed, set status to acknowledgement failed
            for (Opportunity opp : oppsNotSent) {
                opp.Acknowledgment_Status__c = ACKNOWLEDGEMENT_FAILED;
            }
            
            update oppsNotSent;

            reportSendAckStatus();

        } catch (Exception ex) {
            Database.rollback(sp);
            
            // Rollback variables since only DMLs are rolledback.
            // Report none of Opportunities was acknowledged.
            oppsNotSent = [SELECT Name FROM Opportunity WHERE Id IN :oppsToAttemptAck];
            notSentCount = oppsNotSent.size();
            sentCount = 0;

            // Make the error look more readable on the page
            ERR_ExceptionHandler.beautifyExceptionMessage(ex);
            addStatusMessage(ApexPages.Severity.ERROR, ex.getMessage());
        }

        return null;
    }

    /*******************************************************************************************************
    * @description Report send acknowledgement status to the user
    * @return void
    */
    private void reportSendAckStatus() {                 
        if (sentCount > 0) {
            addStatusMessageWithCount(ApexPages.Severity.INFO, System.Label.sendAcknowledgmentNumberSent, sentCount);            
        }       

        if (alreadySentCount > 0) {
             addStatusMessageWithCount(ApexPages.Severity.INFO, System.Label.sendAcknowledgmentNumberAlreadySent, alreadySentCount);            
        }       
                         
        if (notSentCount > 0) {
            addStatusMessageWithCount(ApexPages.Severity.WARNING, System.Label.sendAcknowledgmentNumberNoEmail, notSentCount);                       
        }
    }

    /*******************************************************************************************************
    * @description Action method called to close and return.
    * @return PageReference - null will be redirected via javascript
    */
    public PageReference close() {
        redirect = true;
        return null;
    }

    /*******************************************************************************************************
    * @description Extracts Ids from the list of SObjects
    * @param sobjects - List of SObjects
    * @return Set<Id>
    */
    private Set<Id> extractIds(List<SObject> sobjects) {
        return (new Map<Id, Sobject>(sobjects)).keySet();
    }
    
    /*******************************************************************************************************
    * @description Add a message to the ApexPages context
    * @param Apexpages.Severity - severity of the message
    * @param String - the message to display
    * @return Set<Id>
    */
    private void addStatusMessage(Apexpages.Severity severityLevel, String statusMessage) {
        ApexPages.addMessage(new ApexPages.Message(severityLevel, statusMessage));
    }

    /*******************************************************************************************************
    * @description Add a message to the ApexPages context with a specific count parameter
    * @param Apexpages.Severity - severity of the message
    * @param String - the message to display
    * @param Integer - count parameter to the message
    * @return Set<Id>
    */
    private void addStatusMessageWithCount(Apexpages.Severity severityLevel, String statusMessage, Integer statusCount) {
       addStatusMessage(severityLevel, 
            String.format(
                statusMessage, 
                new List<String>{ String.valueOf(statusCount) }
            )
       );
    }

     /*******************************************************************************************************
    * @description checks if the system should send an email for the particular opportunity
    * @param Opportunity - opportunity to check
    * @return Boolean - returns true if the system should send an acknowledgement email
    */
    private Boolean shouldSendAck(Opportunity opp) {
       return (opp.Acknowledgment_Status__c != ACKNOWLEDGED);
    }

}