// Maps every GoTrue verify result into a closed reason.
// The login panel path: no raw error text ever leaves this function.
export function verifyCode(result) {
  if (result.error) {
    if (result.error.code === "otp_expired") {
      return { ok: false, reason: "expired" };
    }
    return { ok: false, reason: "wrong_code" };
  }
  if (!result.session) {
    return { ok: false, reason: "wrong_code" };
  }
  return { ok: true };
}
