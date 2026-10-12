# Third-party notices

OmniFlow includes code and fonts from the parties below. Each notice is reproduced as its owner supplied it. This file ships inside every OmniFlow build (macOS direct, Mac App Store and iOS).

## Coucou

- **Copyright:** Copyright (c) 2026 Louis Raillé
- **License:** MIT
- **Source:** [github.com/Louis-CFM/coucou](https://github.com/Louis-CFM/coucou)
- **Used in:** the notch island element, originally by Louis Raillé. OmniFlow began as a fork of Coucou; its island window, state machine, session cards and agent hook relay (`OmniFlow/Sources/App`) derive from that code. Its original character, icons and sounds are replaced; legacy internal identifiers remain for compatibility; see `LICENSE-ASSETS.md`.

```text
MIT License

Copyright (c) 2026 Louis Raillé

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Atomic Atlas Go SDK

- **Copyright:** Copyright (c) 2026 Quandry Labs
- **License:** MIT
- **Source:** `Vendor/AtlasSDK`, revision pinned in `OmniFlow/Helpers/Atlas/atlas-sdk.lock.json` and hashes in `Vendor/atlas-sdk-manifest.json`
- **Used in:** the bundled Atlas helper (`Contents/Helpers/NotchLeeAtlas`, macOS direct and Mac App Store builds), built from `OmniFlow/Helpers/Atlas`, and any Swift port of the SDK's runtime. The helper package closure builds offline; other SDK packages declare their own dependencies.

```text
MIT License

Copyright (c) 2026 Quandry Labs

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Quandry Labs focus, monitoring and shortcut-guide code

- **Copyright:** Copyright (c) 2026 Quandry Labs
- **License:** MIT
- **Used in:** pointer focus, system and agent monitoring, and the shortcut guide: `OmniFlowFocusEngine.swift`, `OmniFlowFocusWindow.swift`, `OmniFlowMonitoringAgents.swift`, `OmniFlowMonitoringHardware.swift`, `OmniFlowMonitoringSystem.swift`, `OmniFlowShortcutCatalog.swift` and `OmniFlowShortcutProvider.swift` in `OmniFlow/Sources/App`. Each file also carries the notice in its header.

```text
MIT License

Copyright (c) 2026 Quandry Labs

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## siri-tts-cli private interface

- **Copyright:** Copyright (c) 2026 Max Romer
- **License:** MIT
- **Source:** [github.com/maximilianromer/siri-tts-cli](https://github.com/maximilianromer/siri-tts-cli)
- **Used in:** legacy SiriTTSService interface source retained in `OmniFlow/Helpers/SiriVoice`. Current app targets do not build or bundle this helper; production narration uses Kokoro.

```text
MIT License

Copyright (c) 2026 Max Romer

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Archivo

- **Copyright:** Copyright 2020 The Archivo Project Authors
- **License:** SIL Open Font License 1.1
- **Used in:** interface headings, bundled from `OmniFlow/Resources/Brand`.

```text
Copyright 2020 The Archivo Project Authors (https://github.com/Omnibus-Type/Archivo)

This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
https://openfontlicense.org


-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded, 
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
```

## Roboto

- **Copyright:** Copyright 2011 The Roboto Project Authors
- **License:** SIL Open Font License 1.1
- **Used in:** interface text, bundled from `OmniFlow/Resources/Brand`.

```text
Copyright 2011 The Roboto Project Authors (https://github.com/googlefonts/roboto-classic)

This Font Software is licensed under the SIL Open Font License, Version 1.1.
This license is copied below, and is also available with a FAQ at:
https://openfontlicense.org


-----------------------------------------------------------
SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007
-----------------------------------------------------------

PREAMBLE
The goals of the Open Font License (OFL) are to stimulate worldwide
development of collaborative font projects, to support the font creation
efforts of academic and linguistic communities, and to provide a free and
open framework in which fonts may be shared and improved in partnership
with others.

The OFL allows the licensed fonts to be used, studied, modified and
redistributed freely as long as they are not sold by themselves. The
fonts, including any derivative works, can be bundled, embedded, 
redistributed and/or sold with any software provided that any reserved
names are not used by derivative works. The fonts and derivatives,
however, cannot be released under any other type of license. The
requirement for fonts to remain under this license does not apply
to any document created using the fonts or their derivatives.

DEFINITIONS
"Font Software" refers to the set of files released by the Copyright
Holder(s) under this license and clearly marked as such. This may
include source files, build scripts and documentation.

"Reserved Font Name" refers to any names specified as such after the
copyright statement(s).

"Original Version" refers to the collection of Font Software components as
distributed by the Copyright Holder(s).

"Modified Version" refers to any derivative made by adding to, deleting,
or substituting -- in part or in whole -- any of the components of the
Original Version, by changing formats or by porting the Font Software to a
new environment.

"Author" refers to any designer, engineer, programmer, technical
writer or other person who contributed to the Font Software.

PERMISSION & CONDITIONS
Permission is hereby granted, free of charge, to any person obtaining
a copy of the Font Software, to use, study, copy, merge, embed, modify,
redistribute, and sell modified and unmodified copies of the Font
Software, subject to the following conditions:

1) Neither the Font Software nor any of its individual components,
in Original or Modified Versions, may be sold by itself.

2) Original or Modified Versions of the Font Software may be bundled,
redistributed and/or sold with any software, provided that each copy
contains the above copyright notice and this license. These can be
included either as stand-alone text files, human-readable headers or
in the appropriate machine-readable metadata fields within text or
binary files as long as those fields can be easily viewed by the user.

3) No Modified Version of the Font Software may use the Reserved Font
Name(s) unless explicit written permission is granted by the corresponding
Copyright Holder. This restriction only applies to the primary font name as
presented to the users.

4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font
Software shall not be used to promote, endorse or advertise any
Modified Version, except to acknowledge the contribution(s) of the
Copyright Holder(s) and the Author(s) or with their explicit written
permission.

5) The Font Software, modified or unmodified, in part or in whole,
must be distributed entirely under this license, and must not be
distributed under any other license. The requirement for fonts to
remain under this license does not apply to any document created
using the Font Software.

TERMINATION
This license becomes null and void if any of the above conditions are
not met.

DISCLAIMER
THE FONT SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT
OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE
COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL
DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM
OTHER DEALINGS IN THE FONT SOFTWARE.
```

## Native MLX agent runtime

The optional Mac GLM backend embeds MLX Swift and MLX Swift LM (MIT), with the
Swift Transformers tokenizer (Apache-2.0). Runtime and tokenizer dependencies,
including their upstream notices, are reproduced in the bundled
`MLX-third-party-notices.txt`. Exact dependency revisions are in Package.resolved.
The separately installed GLM-4.7-Flash affine 4-bit model is pinned and verified;
it is not included in the application bundle.

## Kokoro speech: Reader and assistant (macOS, iOS and iPadOS)

Reader narration and assistant replies use FluidAudio's native Core ML implementation. It does not link the
Sherpa ONNX/eSpeak prototype and does not use system speech voices as fallback.
OmniFlow's own license is unchanged. Credit alone does not replace license and
notice obligations; the full texts below are included in every app target.

| Component | Source / revision | License |
|---|---|---|
| FluidAudio SDK | https://github.com/FluidInference/FluidAudio/tree/e560c6445ffdc42e60c7b282d162aae271f18e2a | Apache-2.0 |
| Kokoro-82M v1.0 model and voices | https://huggingface.co/hexgrad/Kokoro-82M | Apache-2.0 |
| Kokoro-82M v1.1-zh model and voices | https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh | Apache-2.0 |
| Core ML conversions | https://huggingface.co/FluidInference/kokoro-82m-coreml | Apache-2.0 |
| Misaki frontend / lexicons | https://github.com/hexgrad/misaki | Apache-2.0 |
| Japanese Cutlet, number conversion | See bundled JapaneseG2P-LICENSE.md | MIT / Apache-2.0 |
| UniDic dictionary | See bundled JapaneseG2P-LICENSE.md | BSD option |
| Spanish/French ipa-dict and CharsiuG2P | See bundled KokoroAneSpanishFrenchG2P-LICENSE.md | MIT |
| NemoTextProcessing binary | text-processing-rs v0.3.1 | Apache-2.0 with permissive transitive dependencies |
| fastcluster | See bundled fastcluster-LICENSE.md | BSD |

Full license texts and upstream notices are under
`OmniFlow/Resources/Kokoro-Licenses/` and copied into the Mac and iOS app bundles.
The downloaded model assets are separate from the application binary. The
library's pinned revision selects the download locations; this notice is not
an assertion that every remote asset is immutable or independently audited.

Model attribution: Kokoro weights and voices by hexgrad; Core ML conversions
and Swift runtime by FluidInference and contributors. The v1.0 model card credits
StyleTTS2 and iSTFTNet, and the Koniwa (CC BY 3.0) and SIWIS (CC BY 4.0) training
sources. The v1.1-zh model card credits LongMaoData. These training-source credits
do not relicense the published Apache-2.0 weights or imply endorsement.

Upstream's Spanish/French lexicons were generated using eSpeak, but its notice
states no eSpeak code is distributed in that frontend. This integration does not
import eSpeak binaries or its data directory. Legacy system speech types remain for compatibility tests, but Reader and
assistant production paths use Kokoro and the Mac no longer builds the private
Siri helper.

## Public source distribution

Freeflow shell and dictation source contributed by Marcus Mingo is included under this repository's MIT license. This does not assert that the private source was previously public or separately MIT-licensed.

The pinned Atomic Atlas Go SDK is included in `Vendor/AtlasSDK`, with its original Quandry Labs MIT license. `Vendor/atlas-sdk-manifest.json` records the source revision, tree ID and SHA-256 of each vendored file. Only SDK source is included, not the Atlas application. Its module metadata lists additional dependencies for other SDK packages; the OmniFlow helper's tested package closure builds with network package downloads disabled. Dependencies retain their own upstream licenses.
