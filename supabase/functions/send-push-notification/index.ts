import { createClient } from "npm:@supabase/supabase-js@2.57.4";
import { importPKCS8, SignJWT } from "npm:jose@6.1.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const FIREBASE_SERVICE_ACCOUNT =
  Deno.env.get("FIREBASE_SERVICE_ACCOUNT")!;

const supabase = createClient(
  SUPABASE_URL,
  SUPABASE_SERVICE_ROLE_KEY,
);

async function getFirebaseAccessToken(serviceAccount: any) {
  const now = Math.floor(Date.now() / 1000);

  const privateKey = await importPKCS8(
    serviceAccount.private_key,
    "RS256",
  );

  const jwt = await new SignJWT({
    scope:
      "https://www.googleapis.com/auth/firebase.messaging",
  })
    .setProtectedHeader({
      alg: "RS256",
      typ: "JWT",
    })
    .setIssuer(serviceAccount.client_email)
    .setAudience("https://oauth2.googleapis.com/token")
    .setIssuedAt(now)
    .setExpirationTime(now + 3600)
    .sign(privateKey);

  const response = await fetch(
    "https://oauth2.googleapis.com/token",
    {
      method: "POST",
      headers: {
        "Content-Type":
          "application/x-www-form-urlencoded",
      },
      body: new URLSearchParams({
        grant_type:
          "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: jwt,
      }),
    },
  );

  if (!response.ok) {
    throw new Error(
      `Google token error: ${await response.text()}`,
    );
  }

  const data = await response.json();
  return data.access_token;
}

export default {
  async fetch(req: Request) {
    try {
      if (req.method !== "POST") {
        return new Response(
          JSON.stringify({
            error: "POST required",
          }),
          {
            status: 405,
            headers: {
              "Content-Type": "application/json",
            },
          },
        );
      }

      const body = await req.json();

      const notificationId =
        body.notification_id ??
        body.record?.id;

      if (!notificationId) {
        return new Response(
          JSON.stringify({
            error: "notification_id is required",
          }),
          {
            status: 400,
            headers: {
              "Content-Type": "application/json",
            },
          },
        );
      }

      const {
        data: notification,
        error: notificationError,
      } = await supabase
        .from("notifications")
        .select(
          "id, player_id, league_id, match_id, type, title, message",
        )
        .eq("id", notificationId)
        .single();

      if (notificationError || !notification) {
        throw new Error(
          notificationError?.message ??
            "Notification not found",
        );
      }

      const {
        data: profile,
        error: profileError,
      } = await supabase
        .from("profiles")
        .select("fcm_token")
        .eq("id", notification.player_id)
        .single();

      if (profileError) {
        throw new Error(profileError.message);
      }

      if (!profile?.fcm_token) {
        return new Response(
          JSON.stringify({
            ok: true,
            skipped: true,
            reason:
              "Player has no FCM token",
          }),
          {
            status: 200,
            headers: {
              "Content-Type":
                "application/json",
            },
          },
        );
      }

      const serviceAccount = JSON.parse(
        FIREBASE_SERVICE_ACCOUNT,
      );

      const accessToken =
        await getFirebaseAccessToken(
          serviceAccount,
        );

      const fcmResponse = await fetch(
        `https://fcm.googleapis.com/v1/projects/${serviceAccount.project_id}/messages:send`,
        {
          method: "POST",
          headers: {
            Authorization:
              `Bearer ${accessToken}`,
            "Content-Type":
              "application/json",
          },
          body: JSON.stringify({
            message: {
              token: profile.fcm_token,

              notification: {
                title: notification.title,
                body: notification.message,
              },

              data: {
                notification_id:
                  String(notification.id),
                type: String(
                  notification.type ?? "",
                ),
                league_id: String(
                  notification.league_id ?? "",
                ),
                match_id: String(
                  notification.match_id ?? "",
                ),
              },

              android: {
                notification: {
                  channel_id:
                    "chibbyball_notifications",
                },
              },
            },
          }),
        },
      );

      const fcmResult =
        await fcmResponse.json();

      if (!fcmResponse.ok) {
        throw new Error(
          `FCM error: ${JSON.stringify(
            fcmResult,
          )}`,
        );
      }

      return new Response(
        JSON.stringify({
          ok: true,
          fcm: fcmResult,
        }),
        {
          status: 200,
          headers: {
            "Content-Type":
              "application/json",
          },
        },
      );
    } catch (error) {
      console.error(error);

      return new Response(
        JSON.stringify({
          error:
            error instanceof Error
              ? error.message
              : String(error),
        }),
        {
          status: 500,
          headers: {
            "Content-Type":
              "application/json",
          },
        },
      );
    }
  },
};
