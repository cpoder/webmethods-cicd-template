package com.example.wm.integration;

import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.apache.kafka.clients.consumer.ConsumerRecords;
import org.apache.kafka.clients.consumer.KafkaConsumer;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import org.apache.kafka.common.serialization.StringDeserializer;
import org.apache.kafka.common.serialization.StringSerializer;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.time.Duration;
import java.util.Collections;
import java.util.Properties;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Kafka produce/consume round trip against the Redpanda sidecar.
 * Plain text only here (matches {@code config/test/kafka-connections.yaml}).
 */
@DisplayName("Redpanda sidecar Kafka round trip")
class KafkaRoundTripIT {

    @Test
    @DisplayName("produce + consume on a fresh topic")
    void produceConsume_directOnRedpanda() throws Exception {
        String topic = "itest." + UUID.randomUUID();
        String key   = "k-" + UUID.randomUUID();
        String value = "hello-kafka-" + UUID.randomUUID();

        Properties producerProps = new Properties();
        producerProps.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, WmIntegrationProps.kafkaBootstrap());
        producerProps.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        producerProps.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG, StringSerializer.class.getName());
        producerProps.put(ProducerConfig.ACKS_CONFIG, "all");
        producerProps.put(ProducerConfig.CLIENT_ID_CONFIG, "rest-assured-producer");

        try (KafkaProducer<String, String> producer = new KafkaProducer<>(producerProps)) {
            producer.send(new ProducerRecord<>(topic, key, value)).get();
            producer.flush();
        }

        Properties consumerProps = new Properties();
        consumerProps.put(ConsumerConfig.BOOTSTRAP_SERVERS_CONFIG, WmIntegrationProps.kafkaBootstrap());
        consumerProps.put(ConsumerConfig.GROUP_ID_CONFIG, "rest-assured-" + UUID.randomUUID());
        consumerProps.put(ConsumerConfig.KEY_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        consumerProps.put(ConsumerConfig.VALUE_DESERIALIZER_CLASS_CONFIG, StringDeserializer.class.getName());
        consumerProps.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");
        consumerProps.put(ConsumerConfig.ENABLE_AUTO_COMMIT_CONFIG, "false");

        try (KafkaConsumer<String, String> consumer = new KafkaConsumer<>(consumerProps)) {
            consumer.subscribe(Collections.singletonList(topic));

            // Poll for up to 10s. Topic auto-create is on by default
            // in Redpanda's docker image, so the first send creates it.
            ConsumerRecord<String, String> match = null;
            long deadline = System.currentTimeMillis() + 10_000;
            while (System.currentTimeMillis() < deadline && match == null) {
                ConsumerRecords<String, String> batch = consumer.poll(Duration.ofMillis(500));
                for (ConsumerRecord<String, String> r : batch) {
                    if (key.equals(r.key()) && value.equals(r.value())) {
                        match = r;
                        break;
                    }
                }
            }

            assertTrue(match != null, "expected to receive the produced record within 10s");
            assertEquals(topic, match.topic());
            assertEquals(key,   match.key());
            assertEquals(value, match.value());
        }
    }
}
