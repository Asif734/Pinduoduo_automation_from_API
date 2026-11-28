import Foundation
import NaturalLanguage

/// Wording instructions and neutral-completion signals used during generation.
enum CustomerFacingReplyPolicy {
    static let wordingBlockedMessage = "Pinduoduo wording blocked this draft. Edit the reply in the merchant app."

    /// Retained wording instructions from the client-managed prompt.
    static let generationInstructions = """
    A video marker without visual evidence does not describe the footage. Answer any usable customer text. If more detail is needed, ask one short question about the problem. Do not imply that you watched the footage.
    Apply this customer-facing wording policy before composing reply_text. Never mention human agents, AI, bots, or automation in customer-visible text, including translations such as 人工、真人、人工智能、机器人、自动客服、自动回复. Do not claim to be a human or a real person. Do not echo those labels from a customer's message or use them in a clarification question. Do not ask whether the customer wants a human agent.
    For an unclear request to switch or transfer service (including a possible typo such as 转亭子), ask one useful question about the customer's actual need or offer help: 您想咨询什么问题？我来帮您看看。 / What would you like help with? Do not invent the intended recipient or promise a transfer. If the product issue is already clear, continue helping with it rather than asking the customer to repeat it. When an existing approved condition authorizes a transfer, use neutral colleague wording: 我为您转接同事继续协助。 / I'll ask a colleague to continue assisting. Keep action and transfer_reason internal, and never describe a colleague as human or as performing special verification. Silently check these rules while drafting; return only the seven-field JSON object, with no policy explanation.
    """

    private static let prohibitedPatterns: [(String, String)] = [
        (#"\b(?:I|we)\s+(?:can(?:not|['’]t)|am\s+unable\s+to|are\s+unable\s+to)\s+(?:view|watch|see|access|open)\s+(?:(?:your|the|this)\s+)?video\b|\b(?:your|the|this)\s+video\s+is\s+(?:still\s+)?(?:loading|processing)\b"#, "video processing status"),
        (#"(?:我|我们|这边).{0,8}(?:无法|不能|看不到|看不了).{0,8}视频|视频.{0,6}(?:还在|仍在|正在)?(?:加载|处理中)"#, "video processing status"),
        (#"(?<![A-Za-z0-9])AI(?![A-Za-z0-9])"#, "AI"),
        (#"\bartificial\s+intelligence\b"#, "artificial intelligence"),
        (#"\bchat\s*bot\b|\bbot\b|\brobots?\b"#, "bot"),
        (#"\bautomation\b|\bautomated\s+(?:assistant|support|service|reply)\b"#, "automation"),
        (#"\b(?:human|live)\s+(?:agent|support|representative|customer\s+service)\b"#, "human agent"),
        (#"\b(?:I(?:['’]m|\s+am)|we(?:['’]re|\s+are))\s+(?:a\s+)?(?:real\s+)?(?:human|person|people)\b"#, "technical identity"),
        (#"\bafter[- ]sales\s+agent\b"#, "after-sales agent"),
        (#"\b(?:agent|representative|colleague|support\s+(?:team|staff)|after[- ]sales\s+(?:team|staff))\b(?:\s*,?\s*(?:who|will|would|can|must|needs?\s+to|has\s+to|is\s+going\s+to|help\s+you|further)){0,5}\s+(?:verify|review|check|confirm)\b"#, "handoff verification"),
        (#"(?:人工|真人|机器人|自动客服|自动回复|自动化)"#, "technical identity"),
        (#"(?:客服|售后人员|售后同事|同事)(?:需要|将|会|来|为您|帮您|协助您|负责){0,4}(?:核实|审核|验证)"#, "handoff verification")
    ]

    static func violation(in reply: String) -> String? {
        for (pattern, label) in prohibitedPatterns
        where reply.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return label
        }
        return nil
    }
}

enum CustomerFacingFallback {
    static let productProblemQuestions = [
        "请问您的产品遇到了什么问题？麻烦您描述一下具体表现，我来帮您排查。",
        "您好，产品使用时出现了什么情况？麻烦说一下具体表现，我帮您看看。",
        "请问产品是在哪一步出现问题的？您可以说说当时发生了什么。",
        "请问这个问题是什么时候出现的？方便的话说一下当时在做什么。",
        "麻烦说一下产品现在的表现，比如无法开机、无法正常使用或有报错，我帮您排查。",
        "请问这个问题是每次使用都会出现，还是偶尔出现？您可以描述一下具体情况。",
        "您好，请问产品使用时有哪些异常？如果有提示信息，也可以一起告诉我。",
        "您能说一下从开始操作到出现问题的过程吗？我根据具体情况帮您排查。",
        "请问产品是完全无法使用，还是某个功能有问题？您可以先说说最明显的表现。",
        "麻烦告诉我您原本想完成什么操作，以及产品实际出现了什么情况。",
        "想帮您尽快找到原因，方便描述一下产品出现问题时的表现吗？"
    ]

    static func productProblemQuestion(history: [PDDChatMessage]) -> String {
        let previous = history.last { message in
            message.sender == .service && productProblemQuestions.contains(message.content)
        }?.content
        let choices = productProblemQuestions.filter { $0 != previous }
        return choices.randomElement() ?? productProblemQuestions[0]
    }

    static func videoQuestion(history: [PDDChatMessage]) -> String {
        let recognizer = NLLanguageRecognizer()
        for message in history.reversed() where message.sender == .customer && message.kind == .text {
            recognizer.reset(); recognizer.processString(message.content)
            switch recognizer.dominantLanguage {
            case .english: return "What would you like me to check in the video?"
            case .spanish: return "¿Qué te gustaría que revisara en el vídeo?"
            case .french: return "Que souhaitez-vous que je vérifie dans la vidéo ?"
            case .german: return "Was soll ich im Video überprüfen?"
            case .japanese: return "動画のどの点を確認すればよいですか？"
            case .korean: return "영상에서 어떤 부분을 확인해 드릴까요?"
            case .bengali: return "ভিডিওর কোন বিষয়টি আপনি আমাকে দেখতে বলছেন?"
            case .hindi: return "आप वीडियो में किस बात की जाँच करवाना चाहते हैं?"
            case .arabic: return "ما الذي تود مني التحقق منه في الفيديو؟"
            case .portuguese: return "O que gostaria que eu verificasse no vídeo?"
            case .russian: return "Что вы хотите, чтобы я проверил в видео?"
            case .simplifiedChinese, .traditionalChinese: return "您希望我重点帮您查看视频中的哪个问题？"
            default: continue
            }
        }
        return "您希望我重点帮您查看视频中的哪个问题？"
    }

    static func handoff(history: [PDDChatMessage]) -> String {
        let recognizer = NLLanguageRecognizer()
        for message in history.reversed() where message.sender == .customer && message.kind == .text {
            recognizer.reset(); recognizer.processString(message.content)
            switch recognizer.dominantLanguage {
            case .english: return "I’ll transfer you to a colleague for further assistance."
            case .spanish: return "Te pasaré con un compañero para que continúe ayudándote."
            case .french: return "Je vais vous mettre en relation avec un collègue pour poursuivre votre demande."
            case .german: return "Ich leite Sie an einen Kollegen weiter, der Ihnen weiterhilft."
            case .japanese: return "引き続き対応できる担当者におつなぎします。"
            case .korean: return "계속 도와드릴 수 있도록 다른 담당자에게 연결해 드리겠습니다."
            case .bengali: return "আরও সহায়তার জন্য আপনাকে একজন সহকর্মীর কাছে স্থানান্তর করছি।"
            case .hindi: return "आगे की सहायता के लिए मैं आपको एक सहकर्मी से जोड़ूँगा।"
            case .arabic: return "سأحوّلك إلى زميل لمواصلة مساعدتك."
            case .portuguese: return "Vou encaminhar você a um colega para continuar o atendimento."
            case .russian: return "Я передам ваш чат коллеге для дальнейшей помощи."
            case .simplifiedChinese, .traditionalChinese: return "我为您转接同事继续协助。"
            default: continue
            }
        }
        return "我为您转接同事继续协助。"
    }
}
