import { verifyCode } from "./phoneAuth/supabaseOtp";

export async function verifyPhoneCode(payload) {
  const { data, error } = await supabase.auth.verifyOtp(payload);
  if (error) {
    logger.error("claim: verifyOtp failed", { message: error.message });
  }
  return verifyCode({ data, error });
}

export function getClaimPhoneErrorMessage(reason) {
  if (reason === "alreadySignedIn") {
    return "auth.alreadySignedIn";
  }
  if (reason === "phone_exists") {
    return "auth.phoneExists";
  }
  return "auth.codeSendError";
}
