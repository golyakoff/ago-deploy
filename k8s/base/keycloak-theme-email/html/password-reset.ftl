<#--
  25-155 Lane B: overrides base's own html/password-reset.ftl (the self-service "forgot password" flow
  on the hosted login page) only to pass the shared shell in template.ftl its hero icon, heading and
  CTA button. The `${kcSanitize(msg("passwordResetBodyHtml", ...))?no_esc}` call is copied
  byte-for-byte from the real base template (org.keycloak.keycloak-themes-26.7.3.jar,
  theme/base/email/html/password-reset.ftl) - the link/expiry copy is untouched, only wrapped.

  `heading` reuses the existing `passwordResetSubject` key, same reasoning as executeActions.ftl.
  `passwordResetCtaLabel` is new, same reasoning too.
-->
<#import "template.ftl" as layout>
<@layout.emailLayout heroIcon="🔒" heading=msg("passwordResetSubject") ctaLink=link ctaLabel=msg("passwordResetCtaLabel")>
${kcSanitize(msg("passwordResetBodyHtml",link, linkExpiration, realmName, linkExpirationFormatter(linkExpiration)))?no_esc}
</@layout.emailLayout>
