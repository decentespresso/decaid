# Issue 728 Feedback Contact Linking

## Goal

Link native in-app feedback to Decent Support without exposing account
credentials or allowing a support-side failure to make an already-created
GitHub issue look like a failed submission.

## Design

Native feedback creates the GitHub issue first. When stored Decent account
credentials are present, Decaid sends a support message whose body is exactly
the GitHub issue URL. The returned contact identifier is then added to the
GitHub issue body with a PATCH request.

`DecentAccountService` owns the authenticated support request. Its existing
serial-mismatch email becomes a caller of the general support-message method.
The returned identifier must be non-empty, must not be `0`, and must be safe to
place inside a single-line Markdown code span.

The complete account lookup, support request, and GitHub PATCH are best-effort
and time-bounded after issue creation. Their failure is logged but does not
change the original successful `FeedbackSubmissionResult`.

## Security Boundary

Only the native feedback dialog receives `DecentAccountService`. The
`POST /api/v1/feedback` construction remains unchanged so a LAN or API caller
cannot trigger authenticated Decent Support messages.

## Verification

Service tests cover the authenticated support request, response validation,
the POST to GET to PATCH sequence, the exact support body, and successful
submission when support linking fails.
