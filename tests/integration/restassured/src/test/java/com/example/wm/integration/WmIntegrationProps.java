package com.example.wm.integration;

/**
 * Central reader for the system properties surfaced by Surefire.
 * <p>
 * Every test class pulls connection coordinates from here so we have
 * exactly one place to update when the compose-file ports change.
 * Defaults match {@code tests/integration/compose.yml}; CI / the
 * {@code scripts/test-integration.sh} driver overrides them via
 * {@code mvn -D...}.
 */
final class WmIntegrationProps {
    private WmIntegrationProps() {}

    static String msrBaseUrl()        { return prop("msr.base.url",        "http://localhost:15555"); }
    static String msrAdminUser()      { return prop("msr.admin.user",      "Administrator"); }
    static String msrAdminPassword()  { return prop("msr.admin.password",  "manage"); }

    static String postgresJdbcUrl()   { return prop("postgres.jdbc.url",   "jdbc:postgresql://localhost:15432/wm_test"); }
    static String postgresUser()      { return prop("postgres.user",       "testuser"); }
    static String postgresPassword()  { return prop("postgres.password",   "testpass"); }

    static String artemisUrl()        { return prop("artemis.url",         "tcp://localhost:61616"); }
    static String artemisUser()       { return prop("artemis.user",        "testuser"); }
    static String artemisPassword()   { return prop("artemis.password",    "testpass"); }

    static String mqttUrl()           { return prop("mqtt.url",            "tcp://localhost:11883"); }

    static String kafkaBootstrap()    { return prop("kafka.bootstrap",     "localhost:19092"); }

    private static String prop(String key, String fallback) {
        String v = System.getProperty(key);
        return (v == null || v.isBlank()) ? fallback : v;
    }
}
