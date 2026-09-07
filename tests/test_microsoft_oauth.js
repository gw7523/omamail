const assert = require("assert")
const { load, deepEqual } = require("./load")

const microsoft = load("providers/MicrosoftOAuth.js")
const outlook = load("providers/Outlook.js")

const clientId = "12345678-1234-4abc-9def-1234567890ab"
deepEqual(outlook.settings("jane@hotmail.com"), {
  imapHost: "outlook.office365.com",
  imapPort: 993,
  smtpHost: "smtp-mail.outlook.com",
  smtpPort: 587,
  username: "jane@hotmail.com",
  aliases: [],
  auth: "",
  tokenAccount: "",
  send: "",
  graphTokenAccount: "",
  insecure: false
})

// A work or school mailbox submits through Microsoft 365's own SMTP host and
// may be told to send through Graph instead; a personal one is unchanged.
const work = outlook.settings("jane@contoso.com", "organizations", "graph")
assert.strictEqual(work.smtpHost, "smtp.office365.com")
assert.strictEqual(work.imapHost, "outlook.office365.com")
assert.strictEqual(work.send, "graph")
assert.strictEqual(outlook.settings("jane@hotmail.com", "", "smtp").send, "", "anything but graph is SMTP")

// The tenant is one path segment of Microsoft's URL and nothing else: a
// stored value cannot steer the sign-in to another host.
assert.strictEqual(microsoft.normalizeTenant(""), "consumers")
assert.strictEqual(microsoft.normalizeTenant(" Organizations "), "organizations")
assert.strictEqual(microsoft.normalizeTenant("contoso.onmicrosoft.com"), "contoso.onmicrosoft.com")
assert.strictEqual(microsoft.normalizeTenant("12345678-1234-4abc-9def-1234567890ab"), "12345678-1234-4abc-9def-1234567890ab")
assert.strictEqual(microsoft.normalizeTenant("evil.example/../consumers"), "consumers", "a path is not a tenant")
assert.strictEqual(microsoft.normalizeTenant("a..b"), "consumers")
assert.strictEqual(microsoft.normalizeTenant("login.microsoftonline.com?x"), "consumers")
assert.strictEqual(microsoft.tokenUrlFor("organizations"),
  "https://login.microsoftonline.com/organizations/oauth2/v2.0/token")
assert.strictEqual(microsoft.deviceUrlFor("bad tenant"), microsoft.DEVICE_URL,
  "an unusable tenant falls back to the consumer authority")
assert.strictEqual(microsoft.isWorkTenant("consumers"), false)
assert.strictEqual(microsoft.isWorkTenant("organizations"), true)

// Graph's token is asked for with the same refresh token and Graph's scope.
const graphBody = microsoft.graphRefreshBody(clientId, "refresh-secret")
assert.ok(graphBody.indexOf("grant_type=refresh_token") >= 0)
assert.ok(graphBody.indexOf("Mail.Send") >= 0)
assert.ok(graphBody.indexOf("IMAP.AccessAsUser.All") < 0, "one resource per token")
assert.strictEqual(microsoft.missingGraphScope("https://graph.microsoft.com/Mail.Send"), false)
assert.strictEqual(microsoft.missingGraphScope("https://graph.microsoft.com/User.Read"), true)
assert.ok(microsoft.graphScopeMessage().indexOf("Mail.Send") >= 0)
assert.strictEqual(microsoft.isValidClientId(clientId), true)
assert.strictEqual(microsoft.isValidClientId("not-a-guid"), false)
assert.strictEqual(microsoft.isValidClientId(""), false)
assert.strictEqual(microsoft.effectiveClientId("  " + clientId + "  "), clientId)

const deviceBody = microsoft.deviceAuthorizationBody(clientId)
assert.ok(deviceBody.indexOf("client_id=" + clientId) >= 0)
assert.ok(deviceBody.indexOf("offline_access") >= 0)
assert.ok(deviceBody.indexOf("IMAP.AccessAsUser.All") >= 0)
assert.ok(deviceBody.indexOf("SMTP.Send") >= 0)

assert.strictEqual(microsoft.verificationUri("https://microsoft.com/devicelogin"),
  "https://microsoft.com/devicelogin")
assert.strictEqual(microsoft.verificationUri("https://login.microsoftonline.com/common/oauth2/deviceauth"),
  "https://login.microsoftonline.com/common/oauth2/deviceauth")
assert.strictEqual(microsoft.verificationUri("https://login.microsoft.com/device"),
  "https://login.microsoft.com/device", "where a work or school tenant sends people")
assert.strictEqual(microsoft.verificationUri("https://www.microsoft.com/link"), "https://www.microsoft.com/link")
assert.strictEqual(microsoft.verificationUri("http://microsoft.com/devicelogin"), "")
assert.strictEqual(microsoft.verificationUri("https://microsoft.com.evil.example/devicelogin"), "")

const device = microsoft.parseDeviceResponse(200, JSON.stringify({
  device_code: "device-secret",
  user_code: "ABCD-EFGH",
  verification_uri: "https://microsoft.com/devicelogin",
  expires_in: 900,
  interval: 7
}))
assert.strictEqual(device.ok, true)
assert.strictEqual(device.deviceCode, "device-secret")
assert.strictEqual(device.userCode, "ABCD-EFGH")
assert.strictEqual(device.interval, 7)
assert.strictEqual(microsoft.parseDeviceResponse(200, JSON.stringify({
  device_code: "secret", user_code: "code", verification_uri: "file:///tmp/trap"
})).ok, false, "the token service cannot make the desktop open a local URI")

deepEqual(microsoft.parseTokenResponse(400,
  JSON.stringify({ error: "authorization_pending" }), ""), {
  ok: false, pending: true, slowDown: false, error: ""
})
assert.strictEqual(microsoft.parseTokenResponse(400,
  JSON.stringify({ error: "slow_down" }), "").slowDown, true)

const token = microsoft.parseTokenResponse(200, JSON.stringify({
  access_token: "access",
  refresh_token: "refresh",
  expires_in: 3600,
  scope: microsoft.SCOPES.join(" ")
}), "")
assert.strictEqual(token.ok, true)
assert.strictEqual(token.accessToken, "access")
assert.strictEqual(token.refreshToken, "refresh")
deepEqual(microsoft.missingMailScopes(token.scope), [])
assert.strictEqual(microsoft.missingMailScopes(
  "https://outlook.office.com/IMAP.AccessAsUser.All").length, 1)
assert.ok(microsoft.missingScopeMessage([
  "https://outlook.office.com/SMTP.Send"
]).indexOf("SMTP.Send") >= 0)

const rotated = microsoft.parseTokenResponse(200, JSON.stringify({
  access_token: "next", expires_in: 3600
}), "saved-refresh")
assert.strictEqual(rotated.refreshToken, "saved-refresh")

const invalid = microsoft.parseTokenResponse(400,
  JSON.stringify({ error: "invalid_grant", error_description: "expired" }), "")
assert.strictEqual(invalid.invalidGrant, true)
assert.strictEqual(microsoft.refreshFailureDisposition(invalid), "signed_out")
assert.ok(microsoft.redact('{"access_token":"eyJsecret.payload.signature","device_code":"secret"}')
  .indexOf("secret") < 0)

console.log("test_microsoft_oauth.js ok")
