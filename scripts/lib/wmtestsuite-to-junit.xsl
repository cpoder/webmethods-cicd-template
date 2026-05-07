<?xml version="1.0" encoding="UTF-8"?>
<!--
    wmtestsuite-to-junit.xsl

    XSLT 1.0 transform: webMethods WmTestSuite raw result file
    (wmTestSuiteResult.xml) -> JUnit Surefire XML for the GitHub
    Actions test-reporter (dorny/test-reporter, mikepenz/...).

    Why XSLT 1.0:
        xsltproc is the only XSLT processor we can rely on across
        Ubuntu / RHEL / WSL / minimal CI runners without pulling in a
        Java/Saxon dependency. xsltproc speaks 1.0; that constraint is
        the reason for the slightly verbose key-based grouping below
        rather than the XSLT 2.0 for-each-group construct.

    Input shape (covers the common variants emitted by the WmTestSuite
    Composite Runner across MSR 10.x / 11.x):

      <wmTestSuiteResult>
        <testSuiteResult name="Greet" packageName="HelloWorld">
          <testCaseResult name="GreetHappyPath"
                          status="passed|failed|error|aborted"
                          time="0.123"
                          serviceUnderTest="hello.world:greet">
            <failureDetails>
              <message>...</message>
              <stackTrace>...</stackTrace>
            </failureDetails>
            <errorDetails> ... </errorDetails>
          </testCaseResult>
          ...
        </testSuiteResult>
        ...
      </wmTestSuiteResult>

    Output (Surefire dialect):

      <testsuites tests="N" failures="F" errors="E" time="T">
        <testsuite name="HelloWorld.Greet" tests="n" failures="f"
                   errors="e" skipped="0" time="t">
          <testcase classname="HelloWorld.Greet"
                    name="GreetHappyPath - hello.world:greet"
                    time="0.123"/>
          <testcase classname="HelloWorld.Greet" name="GreetMissingName"
                    time="0.041">
            <failure type="failed" message="...">stack trace</failure>
          </testcase>
        </testsuite>
        ...
      </testsuites>

    Status mapping:
      passed                -> empty <testcase/>
      skipped|aborted       -> <testcase><skipped/></testcase>
      failed                -> <testcase><failure/></testcase>
      error|<anything else> -> <testcase><error/></testcase>

    The script that drives this transform (scripts/test-unit.sh) is
    the single source of truth for "did the build pass": it counts
    failures+errors and exits non-zero. The XSLT only translates.
-->
<xsl:stylesheet version="1.0"
                xmlns:xsl="http://www.w3.org/1999/XSL/Transform">
    <xsl:output method="xml" indent="yes" encoding="UTF-8"/>
    <xsl:strip-space elements="*"/>

    <!-- ============================================================
         Root: wrap every <testSuiteResult> in <testsuites> with
         aggregate counts.
         ============================================================ -->
    <xsl:template match="/">
        <xsl:variable name="all" select="//testCaseResult"/>
        <testsuites>
            <xsl:attribute name="tests">
                <xsl:value-of select="count($all)"/>
            </xsl:attribute>
            <xsl:attribute name="failures">
                <xsl:value-of select="count($all[translate(@status,'FAILED','failed') = 'failed'])"/>
            </xsl:attribute>
            <xsl:attribute name="errors">
                <xsl:value-of select="count($all[translate(@status,'ERROR','error') = 'error'])"/>
            </xsl:attribute>
            <xsl:attribute name="time">
                <xsl:call-template name="sum-time">
                    <xsl:with-param name="nodes" select="$all"/>
                </xsl:call-template>
            </xsl:attribute>
            <xsl:apply-templates select="//testSuiteResult"/>
        </testsuites>
    </xsl:template>

    <!-- ============================================================
         testSuiteResult -> testsuite
         Suite name = "<package>.<suite>" when packageName is present,
         otherwise just <suite>. Both classname on testcases and the
         suite name use the same form so the GitHub UI groups cases
         consistently.
         ============================================================ -->
    <xsl:template match="testSuiteResult">
        <xsl:variable name="cases" select=".//testCaseResult"/>
        <xsl:variable name="suite-name">
            <xsl:choose>
                <xsl:when test="@packageName and @name">
                    <xsl:value-of select="concat(@packageName, '.', @name)"/>
                </xsl:when>
                <xsl:when test="@name">
                    <xsl:value-of select="@name"/>
                </xsl:when>
                <xsl:otherwise>WmTestSuite</xsl:otherwise>
            </xsl:choose>
        </xsl:variable>
        <testsuite>
            <xsl:attribute name="name"><xsl:value-of select="$suite-name"/></xsl:attribute>
            <xsl:attribute name="tests"><xsl:value-of select="count($cases)"/></xsl:attribute>
            <xsl:attribute name="failures">
                <xsl:value-of select="count($cases[translate(@status,'FAILED','failed') = 'failed'])"/>
            </xsl:attribute>
            <xsl:attribute name="errors">
                <xsl:value-of select="count($cases[translate(@status,'ERROR','error') = 'error'])"/>
            </xsl:attribute>
            <xsl:attribute name="skipped">
                <xsl:value-of select="count($cases[translate(@status,'SKIPED ABORTED','skiped aborted') = 'skipped' or translate(@status,'SKIPED ABORTED','skiped aborted') = 'aborted'])"/>
            </xsl:attribute>
            <xsl:attribute name="time">
                <xsl:call-template name="sum-time">
                    <xsl:with-param name="nodes" select="$cases"/>
                </xsl:call-template>
            </xsl:attribute>
            <xsl:if test="@timestamp">
                <xsl:attribute name="timestamp"><xsl:value-of select="@timestamp"/></xsl:attribute>
            </xsl:if>
            <xsl:apply-templates select=".//testCaseResult">
                <xsl:with-param name="suite-name" select="$suite-name"/>
            </xsl:apply-templates>
        </testsuite>
    </xsl:template>

    <!-- ============================================================
         testCaseResult -> testcase (+optional failure/error/skipped)
         ============================================================ -->
    <xsl:template match="testCaseResult">
        <xsl:param name="suite-name" select="'WmTestSuite'"/>
        <xsl:variable name="status-lc">
            <xsl:value-of select="translate(@status,
                'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
                'abcdefghijklmnopqrstuvwxyz')"/>
        </xsl:variable>
        <xsl:variable name="case-name">
            <xsl:choose>
                <xsl:when test="@name and @serviceUnderTest">
                    <xsl:value-of select="concat(@name, ' - ', @serviceUnderTest)"/>
                </xsl:when>
                <xsl:when test="@name">
                    <xsl:value-of select="@name"/>
                </xsl:when>
                <xsl:otherwise>(unnamed)</xsl:otherwise>
            </xsl:choose>
        </xsl:variable>
        <testcase>
            <xsl:attribute name="classname"><xsl:value-of select="$suite-name"/></xsl:attribute>
            <xsl:attribute name="name"><xsl:value-of select="$case-name"/></xsl:attribute>
            <xsl:attribute name="time">
                <xsl:choose>
                    <xsl:when test="@time"><xsl:value-of select="@time"/></xsl:when>
                    <xsl:otherwise>0</xsl:otherwise>
                </xsl:choose>
            </xsl:attribute>
            <xsl:choose>
                <xsl:when test="$status-lc = 'failed'">
                    <failure>
                        <xsl:attribute name="type">failed</xsl:attribute>
                        <xsl:attribute name="message">
                            <xsl:call-template name="message-of"/>
                        </xsl:attribute>
                        <xsl:call-template name="details-text"/>
                    </failure>
                </xsl:when>
                <xsl:when test="$status-lc = 'skipped' or $status-lc = 'aborted'">
                    <skipped>
                        <xsl:attribute name="message">
                            <xsl:call-template name="message-of"/>
                        </xsl:attribute>
                    </skipped>
                </xsl:when>
                <xsl:when test="$status-lc = 'passed' or $status-lc = 'pass'">
                    <!-- empty testcase = passed -->
                </xsl:when>
                <xsl:otherwise>
                    <error>
                        <xsl:attribute name="type">
                            <xsl:choose>
                                <xsl:when test="@status"><xsl:value-of select="@status"/></xsl:when>
                                <xsl:otherwise>error</xsl:otherwise>
                            </xsl:choose>
                        </xsl:attribute>
                        <xsl:attribute name="message">
                            <xsl:call-template name="message-of"/>
                        </xsl:attribute>
                        <xsl:call-template name="details-text"/>
                    </error>
                </xsl:otherwise>
            </xsl:choose>
        </testcase>
    </xsl:template>

    <!-- ============================================================
         message-of: prefer failureDetails/message, then errorDetails/
         message, then a flat @message attr, then "no message".
         ============================================================ -->
    <xsl:template name="message-of">
        <xsl:choose>
            <xsl:when test="failureDetails/message">
                <xsl:value-of select="normalize-space(failureDetails/message)"/>
            </xsl:when>
            <xsl:when test="errorDetails/message">
                <xsl:value-of select="normalize-space(errorDetails/message)"/>
            </xsl:when>
            <xsl:when test="@message">
                <xsl:value-of select="@message"/>
            </xsl:when>
            <xsl:otherwise>(no message)</xsl:otherwise>
        </xsl:choose>
    </xsl:template>

    <!-- ============================================================
         details-text: dump stackTrace + actualOutputPipeline + any
         child <details> as the body of <failure>/<error>. The text
         is what the GitHub Actions UI shows when you click into a
         failed test, so include enough context to triage.
         ============================================================ -->
    <xsl:template name="details-text">
        <xsl:if test="failureDetails/stackTrace">
            <xsl:value-of select="failureDetails/stackTrace"/>
            <xsl:text>&#10;</xsl:text>
        </xsl:if>
        <xsl:if test="errorDetails/stackTrace">
            <xsl:value-of select="errorDetails/stackTrace"/>
            <xsl:text>&#10;</xsl:text>
        </xsl:if>
        <xsl:if test="actualOutputPipeline">
            <xsl:text>--- actual output pipeline ---&#10;</xsl:text>
            <xsl:value-of select="actualOutputPipeline"/>
            <xsl:text>&#10;</xsl:text>
        </xsl:if>
        <xsl:if test="details">
            <xsl:value-of select="details"/>
        </xsl:if>
    </xsl:template>

    <!-- ============================================================
         sum-time: numeric sum of @time across a node-set. XSLT 1.0
         does not have a sum() that survives missing values, so we
         coerce missing/non-numeric to 0 manually.
         ============================================================ -->
    <xsl:template name="sum-time">
        <xsl:param name="nodes"/>
        <xsl:variable name="rtf">
            <xsl:for-each select="$nodes">
                <n>
                    <xsl:choose>
                        <xsl:when test="@time and string(number(@time)) != 'NaN'">
                            <xsl:value-of select="@time"/>
                        </xsl:when>
                        <xsl:otherwise>0</xsl:otherwise>
                    </xsl:choose>
                </n>
            </xsl:for-each>
        </xsl:variable>
        <xsl:value-of select="format-number(sum(exsl:node-set($rtf)/n) * 1, '0.###')"
                      xmlns:exsl="http://exslt.org/common"/>
    </xsl:template>

</xsl:stylesheet>
