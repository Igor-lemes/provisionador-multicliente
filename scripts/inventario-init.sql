-- Inventário de clientes: fonte de verdade do estado DESEJADO.
-- Banco próprio, fora de qualquer banco de cliente (inventario.db, não versionado).

CREATE TABLE IF NOT EXISTS clientes (
    slug TEXT PRIMARY KEY,
    nome_negocio TEXT NOT NULL,
    subdominio TEXT NOT NULL,
    porta INTEGER NOT NULL,
    path TEXT NOT NULL,
    features TEXT NOT NULL,            -- JSON array, ex.: ["crm","inbox"]
    status TEXT NOT NULL DEFAULT 'ativo',
    -- Qual máquina hospeda a instância: "dev" (controle local) ou "producao"
    -- (via SSH). Ver scripts/servidores.py.
    servidor TEXT NOT NULL DEFAULT 'dev',
    -- Ref de git fixada para ESTE cliente. Vazio = sobe o HEAD do repositório
    -- do app. Preenchido, atualizar-cliente.sh RECUSA subir qualquer outra
    -- coisa: "lembrar de trocar a branch" não é controle, um checkout errado
    -- bastaria para entregar uma versão não aprovada em silêncio. Quem quiser
    -- mudar, muda aqui, de propósito.
    ref_deploy TEXT,
    criado_em TEXT NOT NULL,
    atualizado_em TEXT NOT NULL
);
