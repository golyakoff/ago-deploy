<#--
  25-155 Lane B: overrides base's own html/executeActions.ftl (the invite's own action-token email -
  UPDATE_PASSWORD+UPDATE_PROFILE - `execute-actions-email`, `OperatorInviteEmailProvisioner`) only to
  pass the shared shell in template.ftl its hero icon, heading and CTA button. The
  `requiredActionsText` assignment and the `${kcSanitize(msg("executeActionsBodyHtml", ...))?no_esc}`
  call are copied byte-for-byte from the real base template (org.keycloak.keycloak-themes-26.7.3.jar,
  theme/base/email/html/executeActions.ftl) - the actual link/expiry/required-actions copy is
  untouched, only wrapped.

  `heading` reuses the existing `executeActionsSubject` key rather than a new one - 25-155's own scope
  is "how emails look, not what they say", and the subject line already carries the right words.
  `executeActionsCtaLabel` is new: base has no standalone short button-label key for this flow, only
  the longer inline link text baked into `executeActionsBodyHtml` itself ("Link to account update").
-->
<#outputformat "plainText">
<#assign requiredActionsText><#if requiredActions??><#list requiredActions><#items as reqActionItem>${msg("requiredAction.${reqActionItem}")}<#sep>, </#sep></#items></#list></#if></#assign>
</#outputformat>

<#import "template.ftl" as layout>
<@layout.emailLayout heroIcon="👋" heading=msg("executeActionsSubject") ctaLink=link ctaLabel=msg("executeActionsCtaLabel")>
${kcSanitize(msg("executeActionsBodyHtml",link, linkExpiration, realmName, requiredActionsText, linkExpirationFormatter(linkExpiration)))?no_esc}
</@layout.emailLayout>
