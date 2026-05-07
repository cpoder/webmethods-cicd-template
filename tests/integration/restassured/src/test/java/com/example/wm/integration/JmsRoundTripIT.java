package com.example.wm.integration;

import org.apache.activemq.artemis.jms.client.ActiveMQConnectionFactory;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import javax.jms.Connection;
import javax.jms.ConnectionFactory;
import javax.jms.Destination;
import javax.jms.Message;
import javax.jms.MessageConsumer;
import javax.jms.MessageProducer;
import javax.jms.Session;
import javax.jms.TextMessage;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * JMS produce/consume round trip against the Artemis sidecar.
 *
 * <p>Phase 1 (this test): publish + consume directly through the
 * Artemis JMS client to prove broker connectivity. Phase 2 (added
 * once a packaged service that publishes to {@code testQueue} is
 * available) will publish via MSR and consume here, asserting the
 * MSR-side {@code create_jms_alias} from {@code config/test/} took
 * effect.
 */
@DisplayName("Artemis sidecar JMS round trip")
class JmsRoundTripIT {

    @Test
    @DisplayName("send + receive on a fresh queue")
    void sendReceive_directOnArtemis() throws Exception {
        String queueName = "itest.q." + UUID.randomUUID();
        String body      = "hello-jms-" + UUID.randomUUID();

        ConnectionFactory cf = new ActiveMQConnectionFactory(WmIntegrationProps.artemisUrl());
        try (Connection conn = cf.createConnection(
                WmIntegrationProps.artemisUser(), WmIntegrationProps.artemisPassword())) {
            conn.start();

            try (Session s = conn.createSession(false, Session.AUTO_ACKNOWLEDGE)) {
                Destination dest = s.createQueue(queueName);

                try (MessageProducer p = s.createProducer(dest)) {
                    TextMessage tm = s.createTextMessage(body);
                    tm.setStringProperty("JMSXGroupID", "rest-assured");
                    p.send(tm);
                }

                try (MessageConsumer c = s.createConsumer(dest)) {
                    Message m = c.receive(5_000);
                    assertNotNull(m, "consumer must receive the message we just published");
                    assertTrue(m instanceof TextMessage, "expected TextMessage, got " + m.getClass());
                    assertEquals(body, ((TextMessage) m).getText());
                }
            }
        }
    }
}
