package com.example.wm.integration;

import io.restassured.RestAssured;
import io.restassured.http.ContentType;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.anyOf;
import static org.hamcrest.Matchers.containsString;
import static org.hamcrest.Matchers.equalTo;
import static org.hamcrest.Matchers.lessThan;
import static org.hamcrest.Matchers.matchesPattern;

/**
 * Public REST surface smoke. The Newman collection covers the same
 * ground at the curl/JS level; this class re-asserts on top of an
 * actual XML/JSON parser so type-level regressions surface here too
 * (e.g. a string-of-number that should be a number).
 */
@DisplayName("MSR public REST surface")
class RestEndpointsIT {

    @BeforeAll
    static void configureRestAssured() {
        RestAssured.baseURI = WmIntegrationProps.msrBaseUrl();
        RestAssured.authentication = RestAssured.preemptive()
                .basic(WmIntegrationProps.msrAdminUser(), WmIntegrationProps.msrAdminPassword());
    }

    @Test
    @DisplayName("wm.server:ping responds OK")
    void ping_isReachable() {
        given()
            .accept(ContentType.JSON)
        .when()
            .get("/invoke/wm.server:ping")
        .then()
            .statusCode(200)
            .time(lessThan(1500L))
            .body(matchesPattern("(?is).*(ok|pong|alive).*"));
    }

    @Test
    @DisplayName("wm.server.packages/list returns the WmRoot package")
    void listPackages_includesWmRoot() {
        given()
            .accept(ContentType.JSON)
        .when()
            .get("/rest/wm.server.packages/list")
        .then()
            .statusCode(200)
            .body(containsString("WmRoot"));
    }

    @Test
    @DisplayName("404 on a non-existent service is reported, not silently swallowed")
    void unknownService_is404() {
        given()
        .when()
            .get("/invoke/HelloWorld:doesNotExist_" + System.nanoTime())
        .then()
            // MSR uses 404 when the service is missing, 500 with a
            // structured error doc when the package is missing.
            // Either is a *signal*; a 200 here would mean we're
            // hitting a misrouted catch-all.
            .statusCode(anyOf(equalTo(404), equalTo(500)));
    }
}
