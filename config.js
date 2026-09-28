// =====================================================================
// config.js - Conexao com o Supabase
//
// Estes dois valores sao PUBLICOS e seguros de ficar aqui:
//   - SUPABASE_URL: o Project URL / API URL do seu projeto
//   - SUPABASE_ANON_KEY: a Publishable key (anon/public)
//
// A Publishable key respeita o RLS que criamos no banco, entao mesmo
// exposta ela so consegue ler/escrever o que as politicas permitem.
//
// NUNCA coloque aqui a "Secret key" (service_role). Ela ignora o RLS.
//
// >>> SUBSTITUA os dois valores abaixo pelos do SEU projeto <<<
// =====================================================================

const SUPABASE_URL = "https://bsfikgsrmrxdfzpptzia.supabase.co/";
const SUPABASE_ANON_KEY = "sb_publishable_gSRU3OMxgC-jvkPPUSqKkg_FOjfZ5CB";

// Cria o cliente do Supabase (a biblioteca e carregada no HTML via <script>).
const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
