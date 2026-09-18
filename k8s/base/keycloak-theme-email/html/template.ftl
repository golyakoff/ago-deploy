<#--
  25-155 Lane B: the shared HTML shell for every Keycloak-native email this realm sends through the
  `ago` theme - overrides base's own `html/template.ftl`, whose stock `emailLayout` macro is just
  `<html><body><#nested></body></html>` (extracted 2026-09-18 from the real
  org.keycloak.keycloak-themes-26.7.3.jar running in this cluster's own Keycloak pod - not guessed).

  Ported from this item's own mockup, docs/backlog/25-155-email-template-mockup.html, as closely as
  FreeMarker's own template variables and Keycloak's HTML sanitizer allow - same colours
  (--blue:#2F6CE0, --violet:#7C4DFF for the logo mark's gradient, --ink:#0F1728), same Onest/IBM Plex
  Sans pairing, same table-based bulletproof layout with MSO/VML conditionals for Outlook desktop.

  Two things the mockup has that this shell deliberately drops, because reproducing them here would
  mean inventing new copy rather than restyling existing copy (25-155's own "not about content" scope
  line):
    - the hidden preheader (its text is per-email and there is no slot in Keycloak's own data model to
      carry a fourth line of copy into this shared macro without adding a message key nothing needs);
    - the closing "warm secondary note" box - Keycloak's own *BodyHtml message values (kept unmodified
      by this theme) already end with the exact safety disclaimer ("if you weren't expecting this,
      ignore it") that note would otherwise repeat.
  Everything else - logo row, hero icon, heading, one CTA button, muted footer - is here.

  Why the *body copy* itself is untouched: this file's own `<#nested>` renders whatever the calling
  template already produces via `${kcSanitize(msg(...))?no_esc}` - Keycloak's own base html/*.ftl
  files build that string from a message key this theme does not override, then run it through
  `KeycloakSanitizerMethod` before nesting it here. That sanitizer's own allowlist (read from
  `KeycloakSanitizerPolicy.class` inside keycloak-services-26.7.3.jar, since it ships compiled, not as
  source in this image) is a plain-content allowlist - <p>, <a>, tables, headings, no `style` beyond
  its own narrow CSS property list - so no attempt is made here to style *inside* that nested content.
  Every visually rich element (the card, the buttons, the hero icon tile) lives in this file instead,
  which is never sanitized, so it can use the mockup's real inline styles and gradients directly.
-->
<#macro emailLayout heroIcon="" heading="" ctaLink="" ctaLabel="">
<html lang="${locale.language}" dir="${(ltr)?then('ltr','rtl')}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<meta name="color-scheme" content="light">
<meta name="supported-color-schemes" content="light">
<title>AGO Chat</title>
<!--[if mso]>
<noscript>
<xml>
<o:OfficeDocumentSettings xmlns:o="urn:schemas-microsoft-com:office:office">
<o:PixelsPerInch>96</o:PixelsPerInch>
</o:OfficeDocumentSettings>
</xml>
</noscript>
<style>
  table, td { border-collapse: collapse; }
  .mso-font { font-family: Arial, sans-serif !important; }
</style>
<![endif]-->
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Onest:wght@700;800&family=IBM+Plex+Sans:wght@400;500;600&display=swap" rel="stylesheet" type="text/css">
<style type="text/css">
  body, table, td, a { -webkit-text-size-adjust: 100%; -ms-text-size-adjust: 100%; }
  table, td { mso-table-lspace: 0pt; mso-table-rspace: 0pt; }
  img { -ms-interpolation-mode: bicubic; border: 0; height: auto; line-height: 100%; outline: none; text-decoration: none; }
  body { margin: 0; padding: 0; width: 100% !important; height: 100% !important; background-color: #eef1f8; }
  a { text-decoration: none; }

  @media screen and (max-width: 600px) {
    .email-wrap { width: 100% !important; }
    .fluid { width: 100% !important; max-width: 100% !important; }
    .px-24 { padding-left: 24px !important; padding-right: 24px !important; }
    .h1 { font-size: 22px !important; line-height: 29px !important; }
  }

  @media (prefers-color-scheme: dark) {
    .dark-ignore { background-color: #eef1f8 !important; color: #0f1728 !important; }
  }
</style>
</head>
<body style="margin:0; padding:0; background-color:#eef1f8; font-family: 'IBM Plex Sans', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Arial, sans-serif;">

<center class="dark-ignore" style="width:100%; background-color:#eef1f8;">

<!--[if mso]>
<table role="presentation" width="600" align="center" cellpadding="0" cellspacing="0" border="0"><tr><td>
<![endif]-->

<div class="email-wrap" style="max-width:600px; margin:0 auto;">

  <!-- top spacer -->
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
    <tr><td style="height:40px; line-height:40px; font-size:0;">&nbsp;</td></tr>
  </table>

  <!-- logo row -->
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
    <tr>
      <td align="center" style="padding-bottom:28px;">
        <table role="presentation" cellpadding="0" cellspacing="0" border="0">
          <tr>
            <td valign="middle" bgcolor="#3D5FE0" style="width:32px; height:32px; border-radius:9px; background:#3D5FE0; background-image:linear-gradient(140deg,#2F6CE0,#7C4DFF); text-align:center;">
              <span class="mso-font" style="font-family:'Onest', Arial, sans-serif; font-weight:800; font-size:16px; line-height:32px; color:#ffffff;">A</span>
            </td>
            <td valign="middle" style="padding-left:10px;">
              <span class="mso-font" style="font-family:'Onest', Arial, sans-serif; font-weight:800; font-size:18px; color:#0f1728;">AGO&nbsp;Chat</span>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>

  <!-- main card -->
  <table role="presentation" class="fluid" width="600" cellpadding="0" cellspacing="0" border="0" style="background-color:#ffffff; border-radius:20px; overflow:hidden; box-shadow:0 1px 2px rgba(15,23,40,0.04);">

    <#if heroIcon?has_content || heading?has_content>
    <!-- hero -->
    <tr>
      <td class="px-24" style="padding:44px 48px 8px 48px;" bgcolor="#ffffff">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
          <#if heroIcon?has_content>
          <tr>
            <td align="center" style="padding-bottom:20px;">
              <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                <tr>
                  <td width="64" height="64" align="center" valign="middle" bgcolor="#EEF2FE" style="width:64px; height:64px; border-radius:18px; background-color:#EEF2FE;">
                    <span style="font-family:Arial, sans-serif; font-size:28px; line-height:64px;">${heroIcon}</span>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
          </#if>
          <#if heading?has_content>
          <tr>
            <td align="center">
              <h1 class="h1 mso-font" style="margin:0; font-family:'Onest', Arial, sans-serif; font-weight:800; font-size:26px; line-height:33px; color:#0f1728;">
                ${heading}
              </h1>
            </td>
          </tr>
          </#if>
        </table>
      </td>
    </tr>
    </#if>

    <!-- body copy - the sanitized message content this macro was called with -->
    <tr>
      <td class="px-24" style="padding:20px 48px 4px 48px; font-family:'IBM Plex Sans', Arial, sans-serif; font-size:15px; line-height:24px; color:#1c2536;" bgcolor="#ffffff">
        <#nested>
      </td>
    </tr>

    <#if ctaLink?has_content && ctaLabel?has_content>
    <!-- CTA button, bulletproof for Outlook -->
    <tr>
      <td align="center" style="padding:20px 48px 44px 48px;" bgcolor="#ffffff">
        <!--[if mso]>
        <v:roundrect xmlns:v="urn:schemas-microsoft-com:vml" xmlns:w="urn:schemas-microsoft-com:office:word" href="${ctaLink}" style="height:52px;v-text-anchor:middle;width:280px;" arcsize="19%" stroke="f" fillcolor="#2F6CE0">
        <w:anchorlock/>
        <center style="color:#ffffff;font-family:Arial,sans-serif;font-size:16px;font-weight:bold;">${ctaLabel}</center>
        </v:roundrect>
        <![endif]-->
        <!--[if !mso]><!-->
        <a href="${ctaLink}" target="_blank" style="display:inline-block; background-color:#2F6CE0; color:#ffffff; font-family:'IBM Plex Sans', Arial, sans-serif; font-size:16px; font-weight:600; line-height:24px; padding:14px 40px; border-radius:10px; text-decoration:none;">
          ${ctaLabel}
        </a>
        <!--<![endif]-->
      </td>
    </tr>
    </#if>

  </table>
  <!-- /main card -->

  <!-- footer -->
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
    <tr><td style="height:32px; line-height:32px; font-size:0;">&nbsp;</td></tr>
  </table>

  <table role="presentation" class="fluid" width="600" cellpadding="0" cellspacing="0" border="0">
    <tr>
      <td align="center" class="px-24" style="padding:0 48px;">
        <p style="margin:0 0 6px 0; font-family:'IBM Plex Sans', Arial, sans-serif; font-size:13px; line-height:20px; color:#9aa3ba;">
          ${msg("emailFooterTagline")} ·
          <a href="https://reserve-me.ru" style="color:#6b7686; text-decoration:underline;">reserve-me.ru</a>
        </p>
        <p style="margin:0; font-family:'IBM Plex Sans', Arial, sans-serif; font-size:12px; line-height:19px; color:#b3bac9;">
          ${msg("emailFooterDisclaimer")}
        </p>
      </td>
    </tr>
  </table>

  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
    <tr><td style="height:40px; line-height:40px; font-size:0;">&nbsp;</td></tr>
  </table>

</div>

<!--[if mso]>
</td></tr></table>
<![endif]-->

</center>
</body>
</html>
</#macro>
