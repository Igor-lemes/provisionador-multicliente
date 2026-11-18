"""Testes das partes puras do provisionador (sem SSH, sem rede).
Rodar: python3 -m unittest discover -s tests -v
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest

RAIZ = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SCRIPTS = os.path.join(RAIZ, "scripts")
sys.path.insert(0, SCRIPTS)

import servidores  # noqa: E402
import validacao  # noqa: E402


class Servidores(unittest.TestCase):
    def test_resolver_padrao(self):
        self.assertEqual(servidores.resolver_dest("producao", "cliente-a"), "/home/deploy/clientes/cliente-a")

    def test_path_do_inventario_prevalece(self):
        self.assertEqual(servidores.resolver_dest("producao", "cliente-a", "/srv/app"), "/srv/app")

    def test_recusa_traversal_e_slug_ruim(self):
        for slug, path in [("cliente-a", "/a/../b"), ("Cliente_A", ""), ("x", "relativo"), ("x", "/a b")]:
            with self.assertRaises(ValueError):
                servidores.resolver_dest("producao", slug, path)

    def test_servidor_dev_nao_recebe_provisionamento(self):
        with self.assertRaises(ValueError):
            servidores.clientes_dir("dev")

    def test_guardas_do_rm_rf(self):
        self.assertTrue(servidores.checar_remocao("producao", "cliente-a", "/home/deploy/clientes/cliente-a"))
        self.assertFalse(servidores.checar_remocao("producao", "cliente-a", "/srv/outro/cliente-a"))
        with self.assertRaises(ValueError):
            servidores.checar_remocao("producao", "cliente-a", "/home/deploy/clientes")  # a base
        with self.assertRaises(ValueError):
            servidores.checar_remocao("producao", "cliente-a", "/home/deploy")  # ancestral da base
        with self.assertRaises(ValueError):
            servidores.checar_remocao("producao", "cliente-a", "/srv")  # raso


class Validacao(unittest.TestCase):
    def test_nomes_validos(self):
        for n in ["Cliente A", "Imóveis D'Ávila & Cia", "Clínica (Centro) 2"]:
            self.assertTrue(validacao.nome_negocio_valido(n), n)

    def test_nomes_perigosos(self):
        for n in ['a"b', "a$(id)", "a|b", "a;b", "a`b`", "a\nb", "a%b", "", "x" * 81]:
            self.assertFalse(validacao.nome_negocio_valido(n), repr(n))


class PreencherTemplate(unittest.TestCase):
    def rodar(self, template, env, *nomes):
        with tempfile.TemporaryDirectory() as d:
            t, o = os.path.join(d, "t"), os.path.join(d, "o")
            open(t, "w").write(template)
            r = subprocess.run([sys.executable, os.path.join(SCRIPTS, "preencher-template.py"), t, o, *nomes],
                               env={**os.environ, **env}, capture_output=True, text=True)
            return r, (open(o).read() if os.path.exists(o) else None), (oct(os.stat(o).st_mode & 0o777) if os.path.exists(o) else None)

    def test_valor_com_metacaracteres_e_literal(self):
        r, out, modo = self.rodar("X={{A}}", {"A": "a|b&c/$(id)"}, "A")
        self.assertEqual(r.returncode, 0)
        self.assertEqual(out, "X=a|b&c/$(id)")
        self.assertEqual(modo, "0o600")

    def test_variavel_ausente_falha(self):
        r, out, _ = self.rodar("{{A}}", {}, "A")
        self.assertNotEqual(r.returncode, 0)

    def test_placeholder_sobrando_falha(self):
        r, out, _ = self.rodar("{{A}} {{B}}", {"A": "1"}, "A")
        self.assertNotEqual(r.returncode, 0)

    def test_opcional_pode_ser_vazia(self):
        r, out, _ = self.rodar("[{{A}}]", {}, "?A")
        self.assertEqual((r.returncode, out), (0, "[]"))


class EnvSystemd(unittest.TestCase):
    def test_omite_valor_com_cifrao(self):
        with tempfile.TemporaryDirectory() as d:
            e, s = os.path.join(d, ".env"), os.path.join(d, ".env.systemd")
            open(e, "w").write('A="ok"\nB=$abc\n')
            subprocess.run([sys.executable, os.path.join(SCRIPTS, "gerar-env-systemd.py"), e, s], check=True, capture_output=True)
            out = open(s).read()
            self.assertIn('A="ok"', out)
            self.assertNotIn("B=$abc", out)


class Inventario(unittest.TestCase):
    def test_ciclo_basico(self):
        with tempfile.TemporaryDirectory() as d:
            # copia scripts para isolar o inventario.db (que fica em ../inventario.db)
            import shutil
            os.makedirs(os.path.join(d, "scripts"))
            for f in ("inventario.py", "inventario-init.sql"):
                shutil.copy(os.path.join(SCRIPTS, f), os.path.join(d, "scripts", f))
            inv = [sys.executable, os.path.join(d, "scripts", "inventario.py")]
            run = lambda *a: subprocess.run([*inv, *a], capture_output=True, text=True)
            self.assertEqual(run("existe", "cliente-a").returncode, 1)
            self.assertEqual(run("adicionar", "cliente-a", "Cliente A", "cliente-a.exemplo.com", "8081",
                                 "/home/deploy/clientes/cliente-a", "crm,inbox", "producao").returncode, 0)
            self.assertEqual(run("existe", "cliente-a").returncode, 0)
            info = json.loads(run("info", "cliente-a").stdout)
            self.assertEqual((info["porta"], info["servidor"], info["features"]), (8081, "producao", '["crm", "inbox"]'))
            run("definir-ref", "cliente-a", "--ref", "v1.2.0")
            self.assertEqual(json.loads(run("info", "cliente-a").stdout)["ref_deploy"], "v1.2.0")
            self.assertEqual(run("remover", "cliente-a").returncode, 0)
            self.assertEqual(run("existe", "cliente-a").returncode, 1)


class ArquivosRemovidos(unittest.TestCase):
    def test_lista_so_o_que_saiu_e_protege_env(self):
        with tempfile.TemporaryDirectory() as d:
            g = lambda *a: subprocess.run(["git", "-C", d, *a], check=True, capture_output=True, text=True)
            g("init", "-q"); g("config", "user.email", "t@exemplo.com"); g("config", "user.name", "t")
            for n in ("a.txt", "b.txt", ".env"):
                open(os.path.join(d, n), "w").write(n)
            g("add", "-A"); g("commit", "-qm", "1")
            antigo = g("rev-parse", "--short", "HEAD").stdout.strip()
            g("rm", "-q", "b.txt", ".env"); g("commit", "-qm", "2")
            r = subprocess.run([sys.executable, os.path.join(SCRIPTS, "arquivos-removidos.py"), d, antigo],
                               capture_output=True, text=True)
            self.assertEqual(r.stdout.split(), ["b.txt"])
            self.assertIn(".env", r.stderr)


if __name__ == "__main__":
    unittest.main()
