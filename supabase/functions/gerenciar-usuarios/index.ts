// =====================================================================
// Edge Function: gerenciar-usuarios
// D&A - Rastreamento de Pedidos
//
// Cria usuarios com seguranca a partir do painel do gestor.
//   - Operador (sem e-mail): admin.createUser com e-mail de fachada + senha
//     definida pelo gestor. Ja confirmado, login imediato por usuario+senha.
//   - Com e-mail (editor/representante/visualizador): inviteUserByEmail,
//     a pessoa define a propria senha pelo link do convite.
//
// SEGURANCA:
//   - Usa a service_role key, que fica SO aqui no servidor (nunca no front).
//   - Valida que quem chama e realmente 'gestor' (checa o JWT + tabela profiles).
//   - Cria a linha em profiles com papel e vinculo (vendedor/maquinas).
//
// COMO PUBLICAR (faremos juntos, passo a passo):
//   supabase functions deploy gerenciar-usuarios
// =====================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  // pre-flight CORS
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // ---- 1) cliente admin (service_role) - so no servidor ----
    // Nota: o nome da secret NAO pode comecar com SUPABASE_ (prefixo reservado).
    // Usamos SERVICE_ROLE_KEY. O SUPABASE_URL o Supabase injeta automaticamente.
    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SERVICE_ROLE_KEY") ?? ""
    );

    // ---- 2) validar que QUEM CHAMA e gestor ----
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return json({ error: "Nao autenticado." }, 401);
    }
    const token = authHeader.replace("Bearer ", "");
    const { data: userData, error: userErr } = await supabaseAdmin.auth.getUser(token);
    if (userErr || !userData?.user) {
      return json({ error: "Sessao invalida." }, 401);
    }
    const chamadorId = userData.user.id;

    const { data: perfilChamador, error: perfilErr } = await supabaseAdmin
      .from("profiles")
      .select("papel")
      .eq("id", chamadorId)
      .single();
    if (perfilErr || !perfilChamador || perfilChamador.papel !== "gestor") {
      return json({ error: "Apenas o gestor pode gerenciar usuarios." }, 403);
    }

    // ---- 3) ler os dados do novo usuario ----
    const body = await req.json();
    const acao = body.acao || "criar";

    if (acao === "criar") {
      const {
        nome,
        papel,
        codigo_vendedor,
        maquinas_permitidas,
        // para operador (sem e-mail):
        usuario,      // ex: "joao.silva"
        senha,        // definida pelo gestor
        // para quem tem e-mail:
        email,
      } = body;

      if (!nome || !papel) {
        return json({ error: "Nome e papel sao obrigatorios." }, 400);
      }

      const papeisValidos = ["gestor", "editor", "visualizador", "visualizador_maquina", "representante"];
      if (!papeisValidos.includes(papel)) {
        return json({ error: "Papel invalido." }, 400);
      }

      let novoUserId: string;

      if (email) {
        // ---- fluxo COM e-mail: convite (pessoa cria a propria senha) ----
        const { data: inv, error: invErr } = await supabaseAdmin.auth.admin.inviteUserByEmail(email);
        if (invErr) {
          return json({ error: "Falha ao convidar: " + invErr.message }, 400);
        }
        novoUserId = inv.user.id;
      } else {
        // ---- fluxo OPERADOR: usuario + senha (e-mail de fachada) ----
        if (!usuario || !senha) {
          return json({ error: "Para operador, informe usuario e senha." }, 400);
        }
        if (String(senha).length < 6) {
          return json({ error: "A senha deve ter ao menos 6 caracteres." }, 400);
        }
        // sanitizar o usuario para formar um e-mail de fachada valido
        const login = String(usuario).trim().toLowerCase().replace(/[^a-z0-9._-]/g, "");
        if (!login) {
          return json({ error: "Nome de usuario invalido." }, 400);
        }
        const emailFachada = login + "@operador.daprint.local";

        const { data: novo, error: novoErr } = await supabaseAdmin.auth.admin.createUser({
          email: emailFachada,
          password: String(senha),
          email_confirm: true, // ja confirma, login imediato
          user_metadata: { nome, login },
        });
        if (novoErr) {
          return json({ error: "Falha ao criar operador: " + novoErr.message }, 400);
        }
        novoUserId = novo.user.id;
      }

      // ---- criar o perfil (papel + vinculo) ----
      const perfilNovo: Record<string, unknown> = {
        id: novoUserId,
        nome,
        papel,
      };
      if (papel === "representante" && codigo_vendedor) {
        perfilNovo.codigo_vendedor = codigo_vendedor;
      }
      if (papel === "visualizador_maquina" && Array.isArray(maquinas_permitidas)) {
        perfilNovo.maquinas_permitidas = maquinas_permitidas;
      }

      const { error: insErr } = await supabaseAdmin.from("profiles").insert(perfilNovo);
      if (insErr) {
        // rollback: se o perfil falhar, remove o usuario criado para nao deixar orfao
        await supabaseAdmin.auth.admin.deleteUser(novoUserId);
        return json({ error: "Falha ao criar perfil: " + insErr.message }, 400);
      }

      return json({ ok: true, id: novoUserId }, 200);
    }

    if (acao === "remover") {
      const { id } = body;
      if (!id) return json({ error: "id obrigatorio." }, 400);
      if (id === chamadorId) return json({ error: "Voce nao pode remover a si mesmo." }, 400);
      // remover o usuario do Auth (o perfil cai junto por ON DELETE CASCADE)
      const { error: delErr } = await supabaseAdmin.auth.admin.deleteUser(id);
      if (delErr) return json({ error: "Falha ao remover: " + delErr.message }, 400);
      return json({ ok: true }, 200);
    }

    return json({ error: "Acao desconhecida." }, 400);
  } catch (e) {
    const msg = (e && typeof e === "object" && "message" in e) ? (e as { message: string }).message : String(e);
    return json({ error: "Erro interno: " + msg }, 500);
  }
});

function json(obj: unknown, status: number) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
