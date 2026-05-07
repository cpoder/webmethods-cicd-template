package com.example.wm.integration;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * JDBC round trip: insert via the test client, read back via the same
 * sidecar. This proves Postgres + the schema fixture are wired before
 * the JMS/Kafka/MQTT cases (which depend on MSR being able to talk to
 * the sidecars too).
 *
 * <p>The end-to-end round trip via MSR's {@code testDb} JDBC pool runs
 * in {@link MsrJdbcRoundTripIT}; that one needs a packaged service
 * (delivered in Task 8.3) and is annotated to be skipped until the
 * service exists.
 */
@DisplayName("Postgres sidecar JDBC round trip")
class JdbcRoundTripIT {

    @Test
    @DisplayName("insert + select on audit_events round-trips")
    void auditEvents_insertSelect() throws Exception {
        String correlationId = "rt-" + UUID.randomUUID();

        try (Connection c = DriverManager.getConnection(
                WmIntegrationProps.postgresJdbcUrl(),
                WmIntegrationProps.postgresUser(),
                WmIntegrationProps.postgresPassword())) {

            try (PreparedStatement insert = c.prepareStatement(
                    "INSERT INTO audit_events (correlation_id, event_type, payload) " +
                    "VALUES (?, ?, ?::jsonb)")) {
                insert.setString(1, correlationId);
                insert.setString(2, "ITEST_PROBE");
                insert.setString(3, "{\"who\":\"rest-assured\",\"flag\":true}");
                int n = insert.executeUpdate();
                assertEquals(1, n, "exactly one audit row should be inserted");
            }

            try (PreparedStatement select = c.prepareStatement(
                    "SELECT event_type, payload->>'who' AS who " +
                    "FROM audit_events WHERE correlation_id = ?")) {
                select.setString(1, correlationId);
                try (ResultSet rs = select.executeQuery()) {
                    assertTrue(rs.next(), "select after insert must find the row");
                    assertEquals("ITEST_PROBE", rs.getString("event_type"));
                    assertEquals("rest-assured", rs.getString("who"));
                }
            }
        }
    }

    @Test
    @DisplayName("ping table is writable (smoke for schema fixtures)")
    void pingTable_isWritable() throws Exception {
        try (Connection c = DriverManager.getConnection(
                WmIntegrationProps.postgresJdbcUrl(),
                WmIntegrationProps.postgresUser(),
                WmIntegrationProps.postgresPassword());
             Statement s = c.createStatement()) {
            int n = s.executeUpdate("INSERT INTO ping (note) VALUES ('jdbc-smoke')");
            assertEquals(1, n);
        }
    }
}
