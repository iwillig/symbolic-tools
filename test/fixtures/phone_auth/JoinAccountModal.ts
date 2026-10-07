import { verifyPhoneCode } from "./useClaimAccount";

export function JoinAccountModal(props) {
  const result = verifyPhoneCode(props.payload);
  if (!result.ok) {
    setError(result.message ?? "auth.verifyCodeError");
  }
  return null;
}

function setError(message) {
  console.log(message);
}
