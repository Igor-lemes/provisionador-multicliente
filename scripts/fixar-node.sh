# Fixa o PATH para o mesmo Node com que os serviços dos clientes rodam.
# Sem isso, quem chama os scripts sem o profile do usuário (um serviço
# systemd --user, por exemplo) cai no Node do sistema (outra versão) e
# compila módulos nativos para a ABI errada: tudo quebra com
# "NODE_MODULE_VERSION ... was compiled against a different Node.js version",
# mesmo com um healthcheck raso passando (GET numa página que não toca o banco).
# Uso: source "$SCRIPT_DIR/fixar-node.sh" depois de carregar config.sh.
if [[ -d "${NODE_BIN_DIR:-}" ]]; then
  export PATH="$NODE_BIN_DIR:$PATH"
fi
