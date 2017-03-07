import paho.mqtt.client as mqtt
import paho.mqtt.publish as publish
import paho.mqtt.subscribe as subscribe
import sys

gateways = dict()

def on_connect(_mqttc, obj, flags, status):
    print("connected: status=%s" % (status))
    return

def on_publish(_mqttc, obj, mid):
    print("mid: " + str(mid))
    return

def on_subscribe(_mqttc, obj, mid, granted_qos):
    print("Subscribed: " + str(mid) + " " + str(granted_qos))
    return

def on_log(_mqttc, obj, level, string):
    print(string)
    return

def on_message(_mqttc, obj, msg):
    topic = ''
    url = msg.topic.split('/')
    print('URL: '+str(url))
    print('MSG: '+str(msg.payload))
    typeId = url[2]
    deviceId = url[4]
    event = url[6]
    msg_format = url[8]

    if event == 'ping':
        if typeId not in gateways.keys():
            gateways[typeId] = [deviceId]
        if typeId in gateways.keys() and deviceId not in gateways[typeId]:
            gws = gateways[typeId]
            gws.append(deviceId)
            gateways[typeId] = gws
            for gw in gateways[typeId]:
                topic = 'iot-2/type/'+typeId+'/id/'+gw+'/cmd/ping_update/fmt/'+msg_format
                gw_list_msg = "_".join(gateways[typeId])
                _mqttc.publish(topic, gw_list_msg)
    #if piblished event is a node name, forward to that node's cmd/message topic
    elif event != 'ping' and typeId in gateways.keys() and event in gateways[typeId]:
        topic = 'iot-2/type/'+typeId+'/id/'+event+'/cmd/message/fmt/'+msg_format
        _mqttc.publish(topic, msg.payload)

    elif event != 'ping' and typeId in gateways.keys() and event not in gateways[typeId] and deviceId in gateways[typeId]:
        for gw in gateways[typeId]:
            if gw != deviceId:
                topic = 'iot-2/type/'+typeId+'/id/'+gw+'/cmd/'+event+'/fmt/'+msg_format
                _mqttc.publish(topic, msg.payload)
    else:
        print('Unhandled')

    send_url = topic.split('/')
    print('Send URL:')
    print(send_url)
    return

api_key = sys.argv[1]
auth_token = sys.argv[2]
org_id = sys.argv[3]
relay_id = sys.argv[4]

client_id = 'a:'+org_id+':'+relay_id
host = org_id+'.messaging.internetofthings.ibmcloud.com'


mqttc = mqtt.Client(client_id)
mqttc.username_pw_set(api_key, password=auth_token)

mqttc.on_connect = on_connect
mqttc.on_subscribe = on_subscribe
mqttc.on_message = on_message

mqttc.connect(host=host, port=1883, keepalive=60)

mqttc.subscribe('iot-2/type/+/id/+/evt/+/fmt/+', 0)

mqttc.loop_forever()
