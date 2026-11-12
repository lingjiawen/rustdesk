import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/api_server_warning.dart';
import 'package:flutter_hbb/common/widgets/setting_widgets.dart';
import 'package:flutter_hbb/common/widgets/toolbar.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../common/server_profiles.dart';
import '../../models/platform_model.dart';

void _showSuccess() {
  showToast(translate("Successful"));
}

void setTemporaryPasswordLengthDialog(
    OverlayDialogManager dialogManager) async {
  List<String> lengths = ['6', '8', '10'];
  String length = await bind.mainGetOption(key: "temporary-password-length");
  var index = lengths.indexOf(length);
  if (index < 0) index = 0;
  length = lengths[index];
  dialogManager.show((setState, close, context) {
    setLength(newValue) {
      final oldValue = length;
      if (oldValue == newValue) return;
      setState(() {
        length = newValue;
      });
      bind.mainSetOption(key: "temporary-password-length", value: newValue);
      bind.mainUpdateTemporaryPassword();
      Future.delayed(Duration(milliseconds: 200), () {
        close();
        _showSuccess();
      });
    }

    return CustomAlertDialog(
      title: Text(translate("Set one-time password length")),
      content: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: lengths
              .map(
                (value) => Row(
                  children: [
                    Text(value),
                    Radio(
                        value: value, groupValue: length, onChanged: setLength),
                  ],
                ),
              )
              .toList()),
    );
  }, backDismiss: true, clickMaskDismiss: true);
}

Future<bool> showServerSettings(OverlayDialogManager dialogManager,
    void Function(VoidCallback) setState,
    {bool blank = false}) async {
  await ServerProfiles.load();
  if (blank) {
    return showServerSettingsWithValue(
        ServerConfig(), dialogManager, setState,
        blank: true);
  }
  Map<String, dynamic> options = {};
  try {
    options = jsonDecode(await bind.mainGetOptions());
  } catch (e) {
    print("Invalid server config: $e");
  }
  return showServerSettingsWithValue(
      ServerConfig.fromOptions(options), dialogManager, setState);
}

Future<bool> showServerSettingsWithValue(
    ServerConfig serverConfig,
    OverlayDialogManager dialogManager,
    void Function(VoidCallback)? upSetState,
    {bool blank = false}) async {
  const labelWidth = 120.0;
  const labelSpacing = 8.0;
  var isInProgress = false;
  final idCtrl =
      TextEditingController(text: blank ? '' : serverConfig.idServer);
  final relayCtrl =
      TextEditingController(text: blank ? '' : serverConfig.relayServer);
  final apiCtrl =
      TextEditingController(text: blank ? '' : serverConfig.apiServer);
  final keyCtrl = TextEditingController(text: blank ? '' : serverConfig.key);

  RxString idServerMsg = ''.obs;
  RxString relayServerMsg = ''.obs;
  RxString apiServerMsg = ''.obs;

  final nameCtrl = TextEditingController(
      text: blank ? '' : ServerProfiles.activeName.value);
  final controllers = [idCtrl, relayCtrl, apiCtrl, keyCtrl];
  final errMsgs = [
    idServerMsg,
    relayServerMsg,
    apiServerMsg,
  ];

  final res = await dialogManager.show<bool>((setState, close, context) {
    Future<bool> submit() async {
      setState(() {
        isInProgress = true;
      });
      bool ret = await setServerConfig(
          null,
          errMsgs,
          ServerConfig(
              idServer: idCtrl.text.trim(),
              relayServer: relayCtrl.text.trim(),
              apiServer: apiCtrl.text.trim(),
              key: keyCtrl.text.trim()));
      setState(() {
        isInProgress = false;
      });
      return ret;
    }

    Widget buildField(
        String label, TextEditingController controller, String errorMsg,
        {String? Function(String?)? validator, bool autofocus = false}) {
      if (isDesktop || isWeb) {
        return Row(
          children: [
            SizedBox(
              width: labelWidth,
              child: Text(label),
            ),
            SizedBox(width: labelSpacing),
            Expanded(
              child: serverSettingsTextFormField(
                label: label,
                controller: controller,
                errorMsg: errorMsg,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                showLabelText: false,
                validator: validator,
                autofocus: autofocus,
              ).workaroundFreezeLinuxMint(),
            ),
          ],
        );
      }

      return serverSettingsTextFormField(
        label: label,
        controller: controller,
        errorMsg: errorMsg,
        validator: validator,
      ).workaroundFreezeLinuxMint();
    }

    Future<bool> saveCurrent() async {
      final name = nameCtrl.text.trim();
      final nameErr = ServerProfiles.validateName(name);
      if (nameErr != null) {
        showToast(nameErr);
        return false;
      }
      if (!await submit()) {
        showToast(translate('Failed'));
        return false;
      }
      final err = await ServerProfiles.upsert(ServerProfile(
        name: name,
        idServer: idCtrl.text.trim(),
        relayServer: relayCtrl.text.trim(),
        apiServer: apiCtrl.text.trim(),
        key: keyCtrl.text.trim(),
      ));
      if (err != null) {
        showToast(err);
        return false;
      }
      return true;
    }

    void clearForm() {
      nameCtrl.clear();
      idCtrl.clear();
      relayCtrl.clear();
      apiCtrl.clear();
      keyCtrl.clear();
      setState(() {});
    }

    return CustomAlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(translate('ID/Relay Server'))),
          TextButton.icon(
            onPressed: () async {
              final name = nameCtrl.text.trim();
              final hasBody = idCtrl.text.trim().isNotEmpty ||
                  relayCtrl.text.trim().isNotEmpty ||
                  apiCtrl.text.trim().isNotEmpty ||
                  keyCtrl.text.trim().isNotEmpty;
              if (name.isEmpty && hasBody) {
                showToast('请填写名称');
                return;
              }
              if (name.isNotEmpty) {
                if (!await saveCurrent()) return;
                showToast('已保存 $name');
              }
              clearForm();
            },
            icon: const Icon(Icons.add, size: 18),
            label: const Text('新增'),
          ),
          ...ServerConfigImportExportWidgets(controllers, errMsgs),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 500),
        child: Form(
              child: Obx(() => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  buildField('名称', nameCtrl, ''),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: isDesktop || isWeb
                            ? labelWidth + labelSpacing
                            : 0,
                        bottom: 8,
                      ),
                      child: Text(
                        '点右上角「新增」再加一台。名称用来区分，例如 auth',
                        style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).hintColor),
                      ),
                    ),
                  ),
                  if (ServerProfiles.profiles.isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: EdgeInsets.only(
                          left: isDesktop || isWeb
                              ? labelWidth + labelSpacing
                              : 0,
                          bottom: 8,
                        ),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final profile in ServerProfiles.profiles)
                              InputChip(
                                label: Text(profile.name),
                                selected: profile.name == nameCtrl.text.trim(),
                                onPressed: () async {
                                  nameCtrl.text = profile.name;
                                  idCtrl.text = profile.idServer;
                                  relayCtrl.text = profile.relayServer;
                                  apiCtrl.text = profile.apiServer;
                                  keyCtrl.text = profile.key;
                                  setState(() {});
                                  await ServerProfiles.switchTo(profile.name);
                                },
                                onDeleted: () async {
                                  await ServerProfiles.remove(profile.name);
                                  if (nameCtrl.text.trim() == profile.name) {
                                    nameCtrl.text = ServerProfiles.activeName.value;
                                  }
                                  setState(() {});
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
                  buildField(translate('ID Server'), idCtrl, idServerMsg.value),
                  SizedBox(height: 8),
                  if (!isIOS && !isWeb) ...[
                    buildField(translate('Relay Server'), relayCtrl,
                        relayServerMsg.value),
                    SizedBox(height: 8),
                  ],
                  buildField(
                    translate('API Server'),
                    apiCtrl,
                    apiServerMsg.value,
                    validator: (v) {
                      if (v != null && v.isNotEmpty) {
                        if (!(v.startsWith('http://') ||
                            v.startsWith("https://"))) {
                          return translate("invalid_http");
                        }
                      }
                      return null;
                    },
                  ),
                  Padding(
                    padding: EdgeInsetsDirectional.only(
                      start: isDesktop || isWeb ? labelWidth + labelSpacing : 0,
                    ),
                    child: ApiServerWarning(
                      controller: apiCtrl,
                      idController: idCtrl,
                      message: translate('api_server_connection_tip'),
                      emptyMessage: translate('api_server_empty_tip'),
                    ),
                  ),
                  SizedBox(height: 8),
                  buildField('Key', keyCtrl, ''),
                  if (isInProgress)
                    Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: LinearProgressIndicator(),
                    ),
                ],
              )),
        ),
      ),
      actions: [
        dialogButton('Cancel', onPressed: () {
          close(false);
        }, isOutline: true),
        dialogButton(
          'OK',
          onPressed: () async {
            if (await saveCurrent()) {
              close(true);
              showToast(translate('Successful'));
              upSetState?.call(() {});
            }
          },
        ),
      ],
    );
  });
  return res == true;
}

TextFormField serverSettingsTextFormField({
  required String label,
  required TextEditingController controller,
  required String errorMsg,
  String? Function(String?)? validator,
  bool autofocus = false,
  bool showLabelText = true,
  EdgeInsetsGeometry? contentPadding,
}) {
  return TextFormField(
    controller: controller,
    decoration: InputDecoration(
      labelText: showLabelText ? label : null,
      errorText: errorMsg.isEmpty ? null : errorMsg,
      contentPadding: contentPadding,
    ),
    validator: validator,
    autofocus: autofocus,
    keyboardType: TextInputType.visiblePassword,
    textCapitalization: TextCapitalization.none,
    autocorrect: false,
    enableSuggestions: false,
    smartDashesType: SmartDashesType.disabled,
    smartQuotesType: SmartQuotesType.disabled,
    enableIMEPersonalizedLearning: false,
    spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
  );
}

void setPrivacyModeDialog(
  OverlayDialogManager dialogManager,
  List<TToggleMenu> privacyModeList,
  RxString privacyModeState,
) async {
  dialogManager.dismissAll();
  dialogManager.show((setState, close, context) {
    return CustomAlertDialog(
      title: Text(translate('Privacy mode')),
      content: Column(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: privacyModeList
              .map((value) => CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    title: value.child,
                    value: value.value,
                    onChanged: value.onChanged,
                  ))
              .toList()),
    );
  }, backDismiss: true, clickMaskDismiss: true);
}
