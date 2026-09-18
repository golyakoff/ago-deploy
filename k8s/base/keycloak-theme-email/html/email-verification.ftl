<#--
  25-155 Lane B: overrides base's own html/email-verification.ftl (self-registration's own verify-email
  step) only to pass the shared shell in template.ftl its hero icon, heading and CTA button. The
  `${kcSanitize(msg("emailVerificationBodyHtml", ...))?no_esc}` call is copied byte-for-byte from the
  real base template (org.keycloak.keycloak-themes-26.7.3.jar,
  theme/base/email/html/email-verification.ftl) - the link/expiry copy is untouched, only wrapped.

  Not `email-verification-with-code.ftl` - that is a different, code-only flow this realm's
  `verifyEmail` configuration does not use (confirmed against keycloak-realm-import.json: no
  `emailVerificationWithCode`-style required action or setting is present, only plain `verifyEmail`).

  `heading` reuses the existing `emailVerificationSubject` key, same reasoning as executeActions.ftl.
  `emailVerificationCtaLabel` is new, same reasoning too.
-->
<#import "template.ftl" as layout>
<@layout.emailLayout heroIcon="✉️" heading=msg("emailVerificationSubject") ctaLink=link ctaLabel=msg("emailVerificationCtaLabel")>
${kcSanitize(msg("emailVerificationBodyHtml",link, linkExpiration, realmName, linkExpirationFormatter(linkExpiration)))?no_esc}
</@layout.emailLayout>
