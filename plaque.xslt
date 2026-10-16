<?xml version="1.0" encoding="UTF-8"?>
<!-- Fluffs a fallen hero's plaque, the XML Dungeon#plaque_xml writes, into an XHTML page holding the plaque as
     ASCII art. Each row is padded with dots so the right edge lines up, 41 columns between the bars -->
<xsl:stylesheet version="1.0"
                xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
                xmlns="http://www.w3.org/1999/xhtml">
  <xsl:output method="xml" encoding="UTF-8" indent="no"
              doctype-public="-//W3C//DTD XHTML 1.0 Strict//EN"
              doctype-system="http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd"/>

  <xsl:variable name="dots" select="'...............................'"/>
  <xsl:variable name="spaces" select="'                                         '"/>

  <xsl:template match="/plaque">
    <html>
      <head>
        <title>Wall of Fallen Heroes</title>
        <style type="text/css">body { background: #111; color: #ddd; } pre { font-size: 15px; line-height: 1.1; }</style>
      </head>
      <body>
        <pre>
          <xsl:text> _________________________________________ &#10;</xsl:text>
          <xsl:text>|                                         |&#10;</xsl:text>
          <xsl:text>|          WALL OF FALLEN HEROES          |&#10;</xsl:text>
          <xsl:text>|   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~   |&#10;</xsl:text>
          <xsl:variable name="who">
            <xsl:choose>
              <xsl:when test="normalize-space(name)"><xsl:value-of select="name"/></xsl:when>
              <xsl:otherwise>an unknown hero</xsl:otherwise>
            </xsl:choose>
          </xsl:variable>
          <xsl:value-of select="concat('|   Here lies ', $who, substring($spaces, 1, 28 - string-length($who)), '|&#10;')"/>
          <xsl:value-of select="concat('|   Final score: ', score, substring($spaces, 1, 25 - string-length(score)), '|&#10;')"/>
          <xsl:text>|   In the cage when the end came:        |&#10;</xsl:text>
          <xsl:text>|                                         |&#10;</xsl:text>
          <xsl:call-template name="row">
            <xsl:with-param name="label" select="'Eggs'"/>
            <xsl:with-param name="count" select="eggs"/>
          </xsl:call-template>
          <xsl:call-template name="row">
            <xsl:with-param name="label" select="'Quails'"/>
            <xsl:with-param name="count" select="quails"/>
          </xsl:call-template>
          <xsl:for-each select="critter">
            <xsl:call-template name="row">
              <xsl:with-param name="label" select="@name"/>
              <xsl:with-param name="count" select="."/>
            </xsl:call-template>
          </xsl:for-each>
          <xsl:text>|_________________________________________|&#10;</xsl:text>
          <xsl:text>     ||                             ||     &#10;</xsl:text>
        </pre>
      </body>
    </html>
  </xsl:template>

  <!-- One line of the plaque: |    Label ...... count    | -->
  <xsl:template name="row">
    <xsl:param name="label"/>
    <xsl:param name="count"/>
    <xsl:value-of select="concat('|    ', $label, ' ',
                                 substring($dots, 1, 31 - string-length($label) - string-length($count)),
                                 ' ', $count, '    |&#10;')"/>
  </xsl:template>
</xsl:stylesheet>
