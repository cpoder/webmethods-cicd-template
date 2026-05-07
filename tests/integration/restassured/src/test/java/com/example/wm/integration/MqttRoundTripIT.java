package com.example.wm.integration;

import org.eclipse.paho.client.mqttv3.IMqttClient;
import org.eclipse.paho.client.mqttv3.MqttClient;
import org.eclipse.paho.client.mqttv3.MqttConnectOptions;
import org.eclipse.paho.client.mqttv3.MqttMessage;
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * MQTT publish/subscribe round trip against the Mosquitto sidecar.
 * Same shape as the JMS test: prove the broker is reachable; the
 * Phase-2 MSR-driven case lands once a packaged flow service uses the
 * {@code testBroker} alias.
 */
@DisplayName("Mosquitto sidecar MQTT round trip")
class MqttRoundTripIT {

    @Test
    @DisplayName("publish + subscribe on a fresh topic")
    void publishSubscribe_directOnMosquitto() throws Exception {
        String topic   = "itest/" + UUID.randomUUID();
        String payload = "hello-mqtt-" + UUID.randomUUID();
        String subClientId = "sub-" + UUID.randomUUID();
        String pubClientId = "pub-" + UUID.randomUUID();

        MqttConnectOptions opts = new MqttConnectOptions();
        opts.setCleanSession(true);
        opts.setConnectionTimeout(10);

        AtomicReference<String> received = new AtomicReference<>();
        CountDownLatch latch = new CountDownLatch(1);

        try (IMqttClient sub = new MqttClient(WmIntegrationProps.mqttUrl(), subClientId, new MemoryPersistence())) {
            sub.connect(opts);
            sub.subscribe(topic, 1, (t, msg) -> {
                received.set(new String(msg.getPayload()));
                latch.countDown();
            });

            try (IMqttClient pub = new MqttClient(WmIntegrationProps.mqttUrl(), pubClientId, new MemoryPersistence())) {
                pub.connect(opts);
                MqttMessage m = new MqttMessage(payload.getBytes());
                m.setQos(1);
                pub.publish(topic, m);
                pub.disconnect();
            }

            assertTrue(latch.await(5, TimeUnit.SECONDS),
                    "subscriber must receive the published payload within 5s");
            assertEquals(payload, received.get());

            sub.disconnect();
        }
    }
}
