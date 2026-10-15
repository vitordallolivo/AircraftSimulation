"""Antes de salvar um avião: a lista de verificação (`aerosim.design.checklist`) como caixas de seleção só de
leitura (marcada = ok), por grupo — o que falta definir, requisitos e restrições do projeto — e a pergunta
"salvar mesmo assim?". Nada é bloqueado: quem decide é a pessoa.

    if confirm_save(widget, ac, project):    # sem pendência: True sem perguntar
        salvar(...)
"""
from __future__ import annotations

from PyQt6 import QtCore, QtWidgets

from aerosim.design import checklist as ck

GROUP_TITLES = {ck.DEFINE: "O que falta definir no avião", ck.REQS: "Requisitos do projeto",
                ck.CONS: "Restrições do projeto"}
MARK = {ck.OK: "✔", ck.ATT: "⚠", ck.FAIL: "✘", ck.INFO: "ℹ"}


class SaveCheckDialog(QtWidgets.QDialog):
    def __init__(self, ac, checks: list, parent=None):
        super().__init__(parent)
        self.setWindowTitle(f"Antes de salvar '{ac.name}'")
        self.resize(760, 460)
        v = QtWidgets.QVBoxLayout(self)
        pend = ck.pending(checks)
        head = QtWidgets.QLabel(f"<b>{len(pend)} item(ns) pendente(s).</b> Marcado = ok. Passe o mouse para ver o "
                                "porquê e o que fazer. Dá para salvar mesmo assim e acertar depois.")
        head.setWordWrap(True)
        v.addWidget(head)
        self.only = QtWidgets.QCheckBox("mostrar só o que está pendente")
        self.only.toggled.connect(self._filter)
        v.addWidget(self.only)
        self.tree = QtWidgets.QTreeWidget()
        self.tree.setHeaderLabels(["verificação", "valor", "limite", "o que fazer"])
        self.tree.setRootIsDecorated(True)
        hh = self.tree.header()
        hh.setSectionResizeMode(0, QtWidgets.QHeaderView.ResizeMode.ResizeToContents)
        hh.setSectionResizeMode(3, QtWidgets.QHeaderView.ResizeMode.Stretch)
        groups: dict[str, QtWidgets.QTreeWidgetItem] = {}
        for c in checks:
            g = groups.get(c.group)
            if g is None:
                g = groups[c.group] = QtWidgets.QTreeWidgetItem([GROUP_TITLES.get(c.group, c.group)])
                f = g.font(0)
                f.setBold(True)
                g.setFont(0, f)
                g.setFlags(QtCore.Qt.ItemFlag.ItemIsEnabled)
                self.tree.addTopLevelItem(g)
            it = QtWidgets.QTreeWidgetItem([f"{MARK.get(c.status, '')} {c.item}", c.value, c.criterion, c.fix])
            it.setFlags(QtCore.Qt.ItemFlag.ItemIsEnabled)            # caixa só de leitura
            state = {ck.OK: QtCore.Qt.CheckState.Checked, ck.INFO: QtCore.Qt.CheckState.PartiallyChecked}
            it.setCheckState(0, state.get(c.status, QtCore.Qt.CheckState.Unchecked))
            tip = "\n".join(x for x in (c.why, c.fix and f"o que fazer: {c.fix}", c.source and f"critério: {c.source}") if x)
            for k in range(4):
                it.setToolTip(k, tip)
            it.setData(0, QtCore.Qt.ItemDataRole.UserRole, c.status)
            g.addChild(it)
        self.tree.expandAll()
        v.addWidget(self.tree)
        bb = QtWidgets.QDialogButtonBox()
        self.save_b = bb.addButton("Salvar mesmo assim", QtWidgets.QDialogButtonBox.ButtonRole.AcceptRole)
        self.back_b = bb.addButton("Voltar e corrigir", QtWidgets.QDialogButtonBox.ButtonRole.RejectRole)
        bb.accepted.connect(self.accept)
        bb.rejected.connect(self.reject)
        v.addWidget(bb)
        self.only.setChecked(bool(pend))

    def _filter(self, on: bool) -> None:
        for i in range(self.tree.topLevelItemCount()):
            g = self.tree.topLevelItem(i)
            shown = 0
            for j in range(g.childCount()):
                it = g.child(j)
                hide = on and it.data(0, QtCore.Qt.ItemDataRole.UserRole) not in (ck.ATT, ck.FAIL)
                it.setHidden(hide)
                shown += not hide
            g.setHidden(shown == 0)


def confirm_save(parent, ac, project=None) -> bool:
    """True: salvar (sem pendência ou a pessoa quis salvar mesmo assim)"""
    checks = ck.aircraft_checklist(ac, project)
    if not ck.pending(checks):
        return True
    return SaveCheckDialog(ac, checks, parent).exec() == QtWidgets.QDialog.DialogCode.Accepted
